defmodule KilnCMS.Backups.Heartbeat do
  @moduledoc """
  This node's backup heartbeat (#2218, D9): proof that a backup step running
  here is alive, and the sweep that frees the lock from one that is not.

  Every 30 seconds, on every node:

    1. **Beat**: upsert this node's `KilnCMS.Backups.NodeBeat` (its Oban node
       name, this boot's `KilnCMS.Backups.boot_id/0`, its backup-dir id), with
       the database's `now()`, never this node's clock.
    2. **Sweep**: `KilnCMS.Backups.Chain.reclaim_stale/0` (a holder whose node
       has not beaten for 180 s, or
       restarted, loses the lock and its step is requeued with the attempts it
       has left) and `KilnCMS.Backups.Chain.reap/0` (a holder whose step job
       ended without moving the chain on: the run fails as interrupted and the
       queued request starts). Through the Lock's `:reclaim_stale` action.
    3. Hourly, prune the beats of nodes gone for a day.

  ## Self-fence

  A node that cannot beat (the database is unreachable from here, the beat is
  refused) will soon be declared stale by the others, and its step requeued
  elsewhere. So it stops its own steps first: once its last successful beat is
  90 s old, it kills every process registered in
  `KilnCMS.Backups.StepRegistry` (a step job registers itself), and
  `KilnCMS.ExternalCommand`'s watchers kill the `pg_dump`, `tar` or `rclone`
  each started. Two nodes must never write the same backup's files at once.

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

  alias KilnCMS.Backups
  alias KilnCMS.Backups.DirId

  require Logger

  @interval_ms 30_000
  @fence_after_ms 90_000
  @prune_every_ms :timer.hours(1)

  @type state :: %{
          node: String.t(),
          boot_id: String.t(),
          last_beat: integer() | nil,
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
      started: now_ms(),
      last_prune: nil
    }
  end

  @doc """
  One beat: check the row, beat, fence if beating has failed for too long,
  sweep the lock, prune. Returns the next state. Never raises: each part logs
  its own failure and the next tick tries again.
  """
  @spec tick(state()) :: state()
  def tick(state) do
    state
    |> check_shared_name()
    |> beat()
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
        %{state | last_beat: now_ms()}

      {:error, error} ->
        Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
        state
    end
  rescue
    error ->
      Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
      state
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
