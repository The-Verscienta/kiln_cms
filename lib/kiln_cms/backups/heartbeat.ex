defmodule KilnCMS.Backups.Heartbeat do
  @moduledoc """
  This node's backup heartbeat (#2218, D9): proof that a backup step running
  here is alive, and the sweep that frees the lock from one that is not.

  Every 30 seconds, on every node:

    1. **Beat**: upsert this node's `KilnCMS.Backups.NodeBeat` (its Oban node
       name, this boot's `KilnCMS.Backups.boot_id/0`, its backup-dir id), with
       the database's `now()`, never this node's clock. When the last-good
       marker sync is on (`KilnCMS.Backups.MarkerSyncWorker.enabled?/0`), the
       beat first gives a backup directory that already holds backups its id
       (`KilnCMS.Backups.DirId.ensure_existing/1`), so the sync can reach a
       directory only `scripts/backup.sh` writes to (#2789). An id it can't
       create is reported as none, with one warning per reason per boot.
       That read runs in a task of its own (below), so a backup directory
       that hangs never holds up the beat.
    2. **Run this directory's queue** (#2845), after a successful beat only:
       start (or resume) the backup directory's own Oban queue on this node
       and pause any other, and advertise it in the next beat once it runs
       (`KilnCMS.Backups.DirQueues`, "The directory's queue" below).
    3. **Stop canceled steps**, after a successful beat only (below).
    4. **Sweep**: `KilnCMS.Backups.Chain.reclaim_stale/0` (a holder whose node
       has not beaten for 180 s, or
       restarted, loses the lock and its step is requeued with the attempts it
       has left) and `KilnCMS.Backups.Chain.reap/0` (a holder whose step job
       ended without moving the chain on: the run fails as interrupted and the
       queued request starts). Through the Lock's `:reclaim_stale` action,
       which also sweeps the backup steps stranded in a directory queue
       (`KilnCMS.Backups.Chain.sweep_stranded/0`); the marker syncs stranded
       there are swept after it
       (`KilnCMS.Backups.MarkerSyncWorker.sweep_stranded/0`). A backup
       interrupted there has its run failed in the tick (a finish's, whose
       verdict needs its files, in the task); the rest of its record
       touches `BACKUP_DIR`, so it runs in a task of
       `KilnCMS.Backups.Interrupts`, which the tick never waits on. While
       one of those has run for over a minute (`Interrupts.stalled?/0`),
       the tick skips the lock sweep, logged once each way: another node's
       heartbeat sweeps when its own records aren't stuck too, and a backup
       request on any node still sweeps first (#3078).
    5. Hourly, prune the beats of nodes gone for a day.

  ## Self-fence

  A node that cannot beat (the database is unreachable from here, the beat is
  refused, or the heartbeat itself is stuck) will soon be declared stale by
  the others, and its step requeued elsewhere. So it stops its own steps
  first: once its last successful beat is 90 s old, it kills every process
  registered in `KilnCMS.Backups.StepRegistry` (a step job registers itself),
  and `KilnCMS.ExternalCommand` kills the `pg_dump`, `tar` or `rclone` each
  started when its port closes with it. Two nodes must never write the same
  backup's files at once.

  The kill is done by `KilnCMS.Backups.Fence`, a watchdog process that does no
  file or database I/O and that each successful beat reports to, so it fires
  within a few seconds of the threshold even while a tick is blocked on a
  hung `BACKUP_DIR` (#2848). The tick fences too, when it gets that far.

  ## The backup-directory id read (#2848)

  The id is read (and, with the marker sync on, created) in a task under
  `KilnCMS.Backups.DirIdReaders`, which the tick waits on for at most 5 s.
  One that takes longer is left running, and this heartbeat starts no other
  until it has finished: a process blocked in a file operation on a hung
  mount can't be killed, so one per tick would pile up. A read that answers
  after the tick stopped waiting ends the stall, and the next tick reads
  afresh. Every beat a read holds up
  reports no id: the directory is hung, so the marker sync stops routing to
  this node until it answers again. A stall logs one warning when it starts
  and a line when it clears, and each beat it holds up emits
  `[:kiln_cms, :backups, :heartbeat, :dir_id_timeout]`. A read that crashes,
  or answers with something other than `{:ok, id}` or `{:error, reason}`,
  also reports no id.

  Each beat also reports `last_dir_id` (#2817): the id the last answered
  read gave, kept while a read is held up, crashes or can't start. A resume's
  start counts it as this node reporting its directory, so a copy elsewhere
  doesn't resume from a live node whose read is stuck. The marker sync never
  routes by it. A read that finds no id file clears it.

  A restarted heartbeat starts from the id its node's own beat row holds
  (its `dir_id`, the last read's, else its `last_dir_id`), when that row
  beat within `KilnCMS.Backups.Chain.stale_after_s/0` (180 s) by the
  database's clock (`restore_last_dir_id/1`, #3091): a source host that
  restarts and whose first read hangs still reports its directory, so a copy
  elsewhere doesn't resume beside it. A row older than that, or none, gives
  none until the first read answers.

  The supervisor runs at most four reads at a time, so heartbeats restarted
  on a hung mount can't pile up blocked readers; a tick that finds it full
  starts none and beats with no id. Nothing in the id read stops a beat: an
  error in it is logged and the beat goes out with no id.

  ## The directory's queue (#2845)

  With `KilnCMS.Backups.DirQueues.enabled?/0` on, every successful beat that
  reported a directory id makes sure `backup_dir_<id>` runs here (limit 1,
  this node only), checks it with `Oban.check_queue/1`, and keeps it to
  advertise: the next beat writes it as `dir_queue` (with this boot's id),
  so a job is routed to the queue only once a node runs it. A queue for
  another id is paused at once when the read gives that other id, and after
  180 s when reads give none, and paused again on a later tick if it runs;
  it is resumed when its id comes back, and never stopped, so a running job
  is never orphaned. A queue paused by anything else (an operator, the demo
  reset) is never resumed here, nor advertised while paused. A brand-new directory's
  queue is advertised one or two ticks after its first id read. A start that
  hasn't taken after three ticks logs a warning and emits
  `[:kiln_cms, :backups, :dir_queue, :start_failed]`; until it takes, that
  directory's jobs snooze in `backup_steps` as before #2845. A failed beat
  changes nothing. An error in this part is logged and the tick goes on.

  ## A step whose job was canceled (#2538)

  Cancel (`Oban.cancel_all_jobs/2`) and a reclaim (`Oban.cancel_job/2`) stop
  an executing step through Oban's notifier, which a node cut off from the
  database misses, and a partition that heals before the self-fence fires
  never fences. So after every successful beat this node looks up the Oban
  job of each step registered here (a step registers `{step, job_id}`) and
  kills each one whose job is `cancelled`, `completed` or `discarded`;
  `KilnCMS.ExternalCommand` stops its external command as above. A live
  step's job is `executing` until its own ack, and the step unregisters
  before it returns, so a step in its normal tail, or a new chain's, is never
  stopped.

  A job row that is missing is NOT a reason to kill: a failover to a lagging
  standby or a database restore can lose a row whose step is legitimately
  running. Such a step is left to the self-fence and to the lock's epoch and
  job-id fence (`KilnCMS.Backups.Chain`, ADR 0039), which discards its results
  once its job has been reclaimed or superseded.

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
  off and drives `tick/1` directly). The thresholds are fixed, not configured;
  the id read's wait is `config :kiln_cms, KilnCMS.Backups, dir_id_timeout_ms:`
  (5000 by default).
  """
  use GenServer

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, DirQueues, Fence, Interrupts, MarkerSyncWorker}

  require Logger

  @interval_ms 30_000
  @fence_after_ms 90_000
  @prune_every_ms :timer.hours(1)
  @terminal_job_states ["cancelled", "completed", "discarded"]
  @dir_id_timeout_ms 5_000
  @readers KilnCMS.Backups.DirIdReaders

  @type state :: %{
          node: String.t(),
          boot_id: String.t(),
          last_beat: integer() | nil,
          beat_ok?: boolean(),
          started: integer(),
          last_prune: integer() | nil,
          dir_id_warned: MapSet.t(),
          dir_id_task: dir_id_task() | nil,
          dir_id_stalled?: boolean(),
          readers_full?: boolean(),
          last_dir_id: String.t() | nil,
          dir_id: String.t() | nil,
          dir_queues: DirQueues.state(),
          sweep_skipped?: boolean()
        }

  @typep dir_id_task :: %{
           ref: reference(),
           pid: pid(),
           dir: Path.t(),
           ensure?: boolean(),
           since: integer()
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
    # The directory queues already running here (this heartbeat restarted,
    # Oban didn't): pausing them stays this heartbeat's job, and so does
    # resuming the ones an earlier heartbeat here paused (#3095).
    state = %{new_state(opts) | dir_queues: DirQueues.seeded_state()}
    {:ok, state, {:continue, :tick}}
  end

  # The beat row is read here, not in `init/1`, so a database that doesn't
  # answer doesn't hold up the supervisor.
  @impl GenServer
  def handle_continue(:tick, state),
    do: {:noreply, state |> restore_last_dir_id() |> tick_and_schedule()}

  @impl GenServer
  def handle_info(:tick, state), do: {:noreply, tick_and_schedule(state)}

  # The id read's answer, after the tick stopped waiting for it. It ends the
  # stall; the next tick reads afresh.
  def handle_info({ref, result}, %{dir_id_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {_id, state} = read_done(state, {:result, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{dir_id_task: %{ref: ref}} = state) do
    {_id, state} = read_done(state, :none)
    {:noreply, state}
  end

  # Anything else, a stray reply or `:DOWN` included, is not a reason to stop
  # beating.
  def handle_info(_message, state), do: {:noreply, state}

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
      last_prune: nil,
      dir_id_warned: MapSet.new(),
      dir_id_task: nil,
      dir_id_stalled?: false,
      readers_full?: false,
      last_dir_id: nil,
      dir_id: nil,
      dir_queues: DirQueues.new_state(),
      sweep_skipped?: false
    }
  end

  @doc """
  `state` with the last backup-directory id its node's beat row holds
  (`dir_id`, the id its last beat read, else `last_dir_id`), when that row beat within
  `KilnCMS.Backups.Chain.stale_after_s/0` by the database's clock (#3091).
  What a restarted heartbeat reports as its last id until its first read
  answers. A state that already has one, a row that is older or has none,
  and beats that can't be read leave it. Never raises.
  """
  @spec restore_last_dir_id(state()) :: state()
  def restore_last_dir_id(%{last_dir_id: nil} = state) do
    case Backups.live_beats(Chain.stale_after_s()) do
      {:ok, beats} ->
        case Enum.find(beats, &(&1.node == state.node)) do
          %{} = row -> %{state | last_dir_id: row.dir_id || row.last_dir_id}
          nil -> state
        end

      {:error, error} ->
        log_restore_error(error)
        state
    end
  rescue
    error ->
      log_restore_error(error)
      state
  end

  def restore_last_dir_id(state), do: state

  defp log_restore_error(error) do
    Logger.warning(
      "Backup heartbeat couldn't read its last beat, so it reports no last backup-directory " <>
        "id until its first read answers: " <>
        if(is_exception(error), do: Exception.message(error), else: inspect(error, limit: 5))
    )
  end

  @doc """
  One beat: check the row, beat, run this directory's queue and stop the
  steps whose job was canceled (both after a successful beat), fence if
  beating has failed for too long, sweep the lock, prune. Returns the next
  state. Never raises: each part logs its own failure and the next tick
  tries again.
  """
  @spec tick(state()) :: state()
  def tick(state) do
    state
    |> check_shared_name()
    |> beat()
    |> dir_queues()
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

  # The id read outside the beat's rescue, so a beat that raises still keeps
  # track of a read in flight. An error in the id read itself is no reason
  # not to beat (`init/1` ticks at once, so a raise here would crash-loop the
  # heartbeat and stop the application): it is logged and the beat goes out
  # with no id. The parts that handle a read in flight rescue their own
  # errors, so this keeps its tracking too.
  defp beat(state) do
    {dir_id, state} =
      try do
        dir_id(state)
      rescue
        error ->
          log_dir_id_error(Exception.message(error))
          {nil, state}
      catch
        kind, reason ->
          log_dir_id_error(inspect({kind, reason}))
          {nil, state}
      end

    beat(state, dir_id)
  end

  defp log_dir_id_error(message) do
    Logger.warning(
      "Backup heartbeat: the backup-directory id read failed, beating with no id: " <> message
    )
  end

  defp beat(state, dir_id) do
    attrs = %{
      node: state.node,
      boot_id: state.boot_id,
      dir_id: dir_id,
      last_dir_id: state.last_dir_id,
      dir_queue: state.dir_queues.advertised,
      dir_queue_boot_id: state.dir_queues.advertised && state.boot_id
    }

    state = %{state | dir_id: dir_id}

    case Backups.beat_node(attrs, actor: Backups.system()) do
      {:ok, _beat} ->
        at = now_ms()
        Fence.beat(at)
        Map.merge(state, %{last_beat: at, beat_ok?: true})

      {:error, error} ->
        Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
        Map.put(state, :beat_ok?, false)
    end
  rescue
    error ->
      Logger.warning("Backup heartbeat failed: #{Exception.message(error)}")
      Map.put(state, :beat_ok?, false)
  end

  # After a successful beat only (see "The directory's queue"): the id it
  # reported decides, and what this works out is advertised by the next one.
  defp dir_queues(%{beat_ok?: true} = state) do
    if DirQueues.enabled?() do
      dir_queues = DirQueues.reconcile(state.dir_queues, state.dir_id, now_ms(), state.node)
      %{state | dir_queues: dir_queues}
    else
      state
    end
  rescue
    error ->
      Logger.warning(
        "Backup heartbeat couldn't manage its backup directory's queue: " <>
          Exception.message(error)
      )

      %{state | dir_queues: %{state.dir_queues | advertised: nil}}
  catch
    kind, reason ->
      Logger.warning(
        "Backup heartbeat couldn't manage its backup directory's queue: " <>
          inspect({kind, reason}, limit: 5)
      )

      %{state | dir_queues: %{state.dir_queues | advertised: nil}}
  end

  defp dir_queues(state), do: state

  # The id to report, and the state with the read's progress: the answer of
  # a read that ends during this tick, none while one is held up. A read
  # still running from an earlier tick is only checked, never waited on
  # again or joined by a second one (see "The backup-directory id read").
  defp dir_id(state) do
    {id, state} =
      case state.dir_id_task do
        nil -> state |> start_read() |> await_read(dir_id_timeout_ms())
        _running -> await_read(state, 0)
      end

    if state.dir_id_task, do: {nil, stalled(state)}, else: {id, state}
  end

  # `Backups.dir/0` and the marker sync's switch are read here, in the
  # heartbeat's own process, and handed to the task.
  defp start_read(state) do
    dir = Backups.dir()
    ensure? = MarkerSyncWorker.enabled?()
    reader = dir_id_reader()
    task = Task.Supervisor.async_nolink(@readers, fn -> reader.(dir, ensure?) end)

    %{
      state
      | dir_id_task: %{ref: task.ref, pid: task.pid, dir: dir, ensure?: ensure?, since: now_ms()},
        readers_full?: false
    }
  rescue
    # `async_nolink/2` raises when the supervisor already runs `max_children`
    # reads (heartbeats restarted while earlier reads hang): no read this
    # tick, one warning until a read starts again.
    error in RuntimeError ->
      if state.readers_full? do
        state
      else
        Logger.warning(
          "Backup heartbeat couldn't start the backup-directory id read: " <>
            Exception.message(error) <>
            " (earlier reads of #{Backups.dir()} are still hung?). Beating with no id."
        )

        %{state | readers_full?: true}
      end
  catch
    # The supervisor isn't running (it is started before the heartbeat, so
    # only while the application stops): the beat goes out with what it has.
    :exit, reason ->
      Logger.warning(
        "Backup heartbeat couldn't start the backup-directory id read: " <>
          inspect(reason)
      )

      state
  end

  defp await_read(%{dir_id_task: nil} = state, _timeout), do: {nil, state}

  defp await_read(%{dir_id_task: %{ref: ref}} = state, timeout) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        read_done(state, {:result, result})

      {:DOWN, ^ref, :process, _pid, _reason} ->
        read_done(state, :none)
    after
      timeout -> {nil, state}
    end
  end

  # The id a finished read gives: none for one that crashed (`:none`) or
  # answered something unexpected. The read is over either way.
  defp read_done(%{dir_id_task: task} = state, outcome) do
    if state.dir_id_stalled? do
      Logger.info(
        "Backup heartbeat: the backup-directory id read of #{task.dir} finished after " <>
          "#{div(now_ms() - task.since, 1000)} s"
      )
    end

    state = %{state | dir_id_task: nil, dir_id_stalled?: false}

    case outcome do
      {:result, result} -> dir_id_result(state, task.ensure?, result)
      :none -> {nil, state}
    end
  end

  # With the marker sync off nothing routes by a cron-only directory's id, so
  # the read creates none, and its errors are not worth a warning.
  # `last_dir_id` follows a read that answered: the id, or none when the
  # directory has no id file. An error, a crash or a stall leaves it.
  defp dir_id_result(state, _ensure?, {:ok, id}), do: {id, %{state | last_dir_id: id}}
  defp dir_id_result(state, _ensure?, {:error, :enoent}), do: {nil, %{state | last_dir_id: nil}}
  defp dir_id_result(state, true, {:error, reason}), do: {nil, warn_dir_id(state, reason)}
  defp dir_id_result(state, false, {:error, _reason}), do: {nil, state}

  defp dir_id_result(state, _ensure?, other) do
    log_dir_id_error("unexpected answer " <> inspect(other))
    {nil, state}
  end

  defp stalled(%{dir_id_task: task} = state) do
    waited = now_ms() - task.since

    :telemetry.execute(
      [:kiln_cms, :backups, :heartbeat, :dir_id_timeout],
      %{count: 1, waited_ms: waited},
      %{node: state.node}
    )

    if state.dir_id_stalled? do
      state
    else
      Logger.warning(
        "Backup heartbeat: reading the id of the backup directory #{task.dir} has taken " <>
          "more than #{div(waited, 1000)} s (a hung mount?). Beating with no id, so the " <>
          "last-good marker sync stops routing here; no other read starts until this one " <>
          "finishes."
      )

      %{state | dir_id_stalled?: true}
    end
  end

  @doc false
  # What the read task runs (the default `dir_id_reader`).
  @spec read_dir_id(Path.t(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def read_dir_id(dir, true), do: DirId.ensure_existing(dir)
  def read_dir_id(dir, false), do: DirId.current(dir)

  # `config :kiln_cms, KilnCMS.Backups, dir_id_reader:` (a two-argument
  # function, tests only) and `dir_id_timeout_ms:`.
  defp dir_id_reader, do: Keyword.get(backups_env(), :dir_id_reader, &read_dir_id/2)

  defp dir_id_timeout_ms, do: Keyword.get(backups_env(), :dir_id_timeout_ms, @dir_id_timeout_ms)

  defp backups_env, do: Application.get_env(:kiln_cms, KilnCMS.Backups, [])

  defp warn_dir_id(state, reason) do
    if MapSet.member?(state.dir_id_warned, reason) do
      state
    else
      Logger.warning(
        "Backup heartbeat: no id for the backup directory #{Backups.dir()} " <>
          "(#{inspect(reason)}). The last-good marker sync can't route to it, so it is " <>
          "synced only in the slots this node runs the sync job."
      )

      %{state | dir_id_warned: MapSet.put(state.dir_id_warned, reason)}
    end
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

  # The tick's own fence; `KilnCMS.Backups.Fence` also fires while a tick is
  # stuck.
  defp fence(state) do
    since = state.last_beat || state.started
    elapsed = now_ms() - since
    if elapsed >= @fence_after_ms, do: Fence.kill_steps(elapsed)
    state
  end

  # The Lock's `:reclaim_stale` action: `Chain.reclaim_stale/0`,
  # `Chain.reap/0`, then `Chain.sweep_stranded/0` (each logs and reports what
  # it did); then the marker syncs stranded in a directory queue.
  #
  # Skipped while an interrupt record here has run for over a minute
  # (`Interrupts.stalled?/0`, a hung BACKUP_DIR): this node would only queue
  # the next one behind it, so another node's heartbeat, or a backup request,
  # sweeps instead. Nothing guarantees one does: on a shared mount hung for
  # every node, only requests sweep until it answers (#3078).
  defp sweep(state) do
    state = sweep_lock(state, Interrupts.stalled?())
    sweep_marker_syncs()
    state
  end

  defp sweep_lock(state, true = _stalled?) do
    unless state.sweep_skipped? do
      Logger.warning(
        "Backup heartbeat: an interrupt record on this node has run for over a minute " <>
          "(a hung BACKUP_DIR?), so this node's heartbeat skips the backup lock sweep until " <>
          "it finishes; other nodes' heartbeats and backup requests still sweep"
      )
    end

    %{state | sweep_skipped?: true}
  end

  defp sweep_lock(state, false) do
    if state.sweep_skipped? do
      Logger.info("Backup heartbeat: the interrupt records here caught up; sweeping again")
    end

    case Backups.reclaim_stale_backups(actor: Backups.system()) do
      {:ok, _outcome} ->
        :ok

      {:error, error} ->
        Logger.warning("Backup lock sweep failed: #{Exception.message(error)}")
    end

    %{state | sweep_skipped?: false}
  rescue
    error ->
      Logger.warning("Backup lock sweep failed: #{Exception.message(error)}")
      %{state | sweep_skipped?: false}
  end

  defp sweep_marker_syncs do
    MarkerSyncWorker.sweep_stranded()
  rescue
    error ->
      Logger.warning(
        "Backup heartbeat couldn't sweep the stranded marker syncs: #{Exception.message(error)}"
      )
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
