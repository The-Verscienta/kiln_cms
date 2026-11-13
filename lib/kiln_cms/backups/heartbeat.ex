defmodule KilnCMS.Backups.Heartbeat do
  @moduledoc """
  This node's backup heartbeat (#2218, D9): proof that a backup step running
  here is alive, and the sweep that frees the lock from one that is not.

  Every 30 seconds, on every node:

    1. **Beat**: upsert this node's `KilnCMS.Backups.NodeBeat` (its Oban node
       name, this boot's `KilnCMS.Backups.boot_id/0`, its backup-dir id), with
       the database's `now()`, never this node's clock.
    2. **Stop canceled steps**, after a successful beat only (below).
    3. **Sweep**: `KilnCMS.Backups.Chain.reclaim_stale/0` (a holder whose node
       has not beaten for 180 s, or
       restarted, loses the lock and its step is requeued with the attempts it
       has left) and `KilnCMS.Backups.Chain.reap/0` (a holder whose step job
       ended without moving the chain on: the run fails as interrupted and the
       queued request starts). Through the Lock's `:reclaim_stale` action.
    4. Hourly, prune the beats of nodes gone for a day.

  ## Self-fence

  A node that cannot beat (the database is unreachable from here, the beat is
  refused) will soon be declared stale by the others, and its step requeued
  elsewhere. So it stops its own steps first: once its last successful beat is
  90 s old, it kills every process registered in
  `KilnCMS.Backups.StepRegistry` (a step job registers itself), and
  `KilnCMS.ExternalCommand`'s watchers kill the `pg_dump`, `tar` or `rclone`
  each started. Two nodes must never write the same backup's files at once.

  ## A step whose job was canceled (#2538)

  Cancel (`Oban.cancel_all_jobs/2`) and a reclaim (`Oban.cancel_job/2`) stop
  an executing step through Oban's notifier, which a node cut off from the
  database misses, and a partition that heals before the self-fence fires
  never fences. So after every successful beat this node looks up the Oban
  job of each step registered here (a step registers `{step, job_id}`) and
  kills each one whose job is `cancelled`, `completed` or `discarded`; the
  watchers stop its external command as above. A live step's job is
  `executing` until its own ack, and the step unregisters before it returns,
  so a step in its normal tail, or a new chain's, is never stopped.

  A job row that is missing is NOT a reason to kill: a failover to a lagging
  standby or a database restore can lose a row whose step is legitimately
  running. Such a step is left to the self-fence and the lock's lease.

  A node that reconnects stops the step on its first successful beat, at
  most one interval later. A beat that hangs on a half-open connection
  (database timeouts) delays that, and the self-fence with it.

  ## Node names must be unique

  The beat is keyed by `Oban.config().node`, the name a job's `attempted_by`
  records. Two nodes sharing a name would overwrite each other's beat, and one
  could look restarted to the sweep while it runs a step. A beat row whose boot
  id changed since this node's last beat is logged as an error saying so.

  Started after Oban in `KilnCMS.Application` when `config :kiln_cms,
  KilnCMS.Backups, heartbeat?: true` (the default; the test build turns it
  off and drives `tick/1` directly). The thresholds are fixed, not configured.
  """
  use GenServer

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.DirId

  require Logger

  @interval_ms 30_000
  @fence_after_ms 90_000
  @prune_every_ms :timer.hours(1)
  @terminal_job_states ["cancelled", "completed", "discarded"]

  @type state :: %{
          node: String.t(),
          boot_id: String.t(),
          last_beat: integer() | nil,
          beat_ok?: boolean(),
          started: integer(),
          last_prune: integer() | nil
        }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Milliseconds between beats."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc "Milliseconds without a successful beat after which this node kills its steps."
  @spec fence_after_ms() :: pos_integer()
  def fence_after_ms, do: @fence_after_ms

  @doc """
  Milliseconds by when a node cut off from the database has stopped its steps,
  or, if it reconnected, been told to: the fence threshold, plus one beat
  interval for the tick that notices it, plus 30 s of slack.
  """
  @spec settled_after_ms() :: pos_integer()
  def settled_after_ms, do: @fence_after_ms + @interval_ms + 30_000

  @impl GenServer
  def init(opts) do
    {:ok, new_state(opts), {:continue, :tick}}
  end

  @impl GenServer
  def handle_continue(:tick, state), do: {:noreply, tick_and_schedule(state)}

  @impl GenServer
  def handle_info(:tick, state), do: {:noreply, tick_and_schedule(state)}

  defp tick_and_schedule(state) do
    state = tick(state)
    Process.send_after(self(), :tick, @interval_ms)
    state
  end

  @doc """
  The state a heartbeat starts from. Options: `:node` (default
  `Oban.config().node`) and `:boot_id` (default `Backups.boot_id/0`).
  """
  @spec new_state(keyword()) :: state()
  def new_state(opts \\ []) do
    %{
      node: Keyword.get_lazy(opts, :node, fn -> Oban.config().node end),
      boot_id: Keyword.get_lazy(opts, :boot_id, &Backups.boot_id/0),
      last_beat: nil,
      beat_ok?: false,
      started: now_ms(),
      last_prune: nil
    }
  end

  @doc """
  One beat: check the row, beat, stop the steps whose job was canceled (after
  a successful beat), fence if beating has failed for too long, sweep the
  lock, prune. Returns the next state. Never raises: each part logs its own
  failure and the next tick tries again.
  """
  @spec tick(state()) :: state()
  def tick(state) do
    state
    |> check_shared_name()
    |> beat()
    |> stop_canceled()
    |> fence()
    |> sweep()
    |> prune()
  end

  # W9: the row says another boot wrote it since this node's last beat, so
  # another node beats under this node's name.
  defp check_shared_name(%{last_beat: nil} = state), do: state

  defp check_shared_name(state) do
    case Backups.get_node_beat(state.node, actor: Backups.system()) do
      {:ok, %{boot_id: boot_id}} when boot_id != state.boot_id ->
        Logger.error(
          "Backup heartbeat: another node is beating as #{inspect(state.node)} " <>
            "(boot #{boot_id}, this node is #{state.boot_id}). Oban node names must be " <>
            "unique per node, or a running backup step can be reclaimed from a live node."
        )

      _ ->
        :ok
    end

    state
  rescue
    error ->
      Logger.warning("Backup heartbeat couldn't read its beat: #{Exception.message(error)}")
      state
  end

  defp beat(state) do
    dir_id =
      case DirId.current() do
        {:ok, id} -> id
        _ -> nil
      end

    attrs = %{node: state.node, boot_id: state.boot_id, dir_id: dir_id}

    case Backups.beat_node(attrs, actor: Backups.system()) do
      {:ok, _beat} ->
        Map.merge(state, %{last_beat: now_ms(), beat_ok?: true})

      {:error, error} ->
        Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
        Map.put(state, :beat_ok?, false)
    end
  rescue
    error ->
      Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
      Map.put(state, :beat_ok?, false)
  end

  # Only after a successful beat: the job states it reads are then the
  # database's current ones, not a guess from a node that can't reach it.
  defp stop_canceled(%{beat_ok?: true} = state) do
    case registered_jobs() do
      [] -> :ok
      steps -> stop_terminal(steps)
    end

    state
  rescue
    error ->
      Logger.warning(
        "Backup heartbeat couldn't check its steps' jobs: #{Exception.message(error)}"
      )

      state
  end

  defp stop_canceled(state), do: state

  # `{pid, job_id}` of every step registered with a job id. Other values (a
  # step from before #2538 registered its name alone) are left to the fence.
  defp registered_jobs do
    Registry.select(KilnCMS.Backups.StepRegistry, [
      {{:_, :"$1", {:_, :"$2"}}, [{:is_integer, :"$2"}], [{{:"$1", :"$2"}}]}
    ])
  end

  defp stop_terminal(steps) do
    ids = steps |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    states =
      KilnCMS.Repo.all(from(j in Oban.Job, where: j.id in ^ids, select: {j.id, j.state}))
      |> Map.new()

    # A missing row is not terminal: see the moduledoc.
    pids =
      for {pid, id} <- steps, Map.get(states, id) in @terminal_job_states, uniq: true, do: pid

    if pids != [] do
      Logger.error(
        "Backup heartbeat: stopping #{length(pids)} backup step(s) whose job was canceled " <>
          "or has ended, a signal this node missed while it couldn't reach the database"
      )

      Enum.each(pids, &Process.exit(&1, :kill))
    end
  end

  defp fence(state) do
    since = state.last_beat || state.started

    if now_ms() - since >= @fence_after_ms do
      case step_pids() do
        [] ->
          :ok

        pids ->
          Logger.error(
            "Backup heartbeat: no successful beat for #{div(now_ms() - since, 1000)} s; " <>
              "stopping #{length(pids)} backup step(s) on this node before another node " <>
              "takes them over"
          )

          Enum.each(pids, &Process.exit(&1, :kill))
      end
    end

    state
  end

  defp step_pids do
    KilnCMS.Backups.StepRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  # The Lock's `:reclaim_stale` action: `Chain.reclaim_stale/0`, then
  # `Chain.reap/0` (each logs and reports what it did).
  defp sweep(state) do
    case Backups.reclaim_stale_backups(actor: Backups.system()) do
      {:ok, _outcome} ->
        :ok

      {:error, error} ->
        Logger.warning("Backup lock sweep failed: #{Exception.message(error)}")
    end

    state
  rescue
    error ->
      Logger.warning("Backup lock sweep failed: #{Exception.message(error)}")
      state
  end

  defp prune(%{last_prune: at} = state) when is_integer(at) do
    if now_ms() - at >= @prune_every_ms, do: do_prune(state), else: state
  end

  defp prune(state), do: do_prune(state)

  defp do_prune(state) do
    _ = Backups.prune_node_beats(actor: Backups.system())
    %{state | last_prune: now_ms()}
  rescue
    error ->
      Logger.warning("Backup heartbeat couldn't prune old beats: #{Exception.message(error)}")
      %{state | last_prune: now_ms()}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
