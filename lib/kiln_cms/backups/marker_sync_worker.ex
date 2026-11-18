defmodule KilnCMS.Backups.MarkerSyncWorker do
  @moduledoc """
  Keeps the last-good markers (`kiln-<stamp>.good`) in step for deployments
  whose backups come from host cron (#2554), and the hold markers
  (`kiln-<stamp>.hold`) that tell `backup.sh prune` what the in-app
  schedules keep (#2219). A schedule's create, update or destroy also queues
  one run of this job (`KilnCMS.Backups.Schedule.Changes.SyncHolds`), so the
  holds catch up at once.

  The app writes a marker after its own backup succeeds or prunes. A
  deployment that backs up only with `scripts/backup.sh` runs neither, so
  without this job its `backup.sh prune` keeps only the newest complete set,
  even when that set came from a failed run. Every 15 minutes
  (`KILN_BACKUP_MARKER_SYNC_CRON`, `*/15 * * * *` by default, `false` turns it
  off) this job runs `Chain.sync_last_good/2`: the importer, then the marker
  sync under the backup lock, skipped while a backup runs (that backup syncs
  the markers itself).

  It does not depend on `BACKUP_ENABLED`, which turns off the in-app backup
  path only: the marker exists for the cron path, and a deployment that backs
  up only with cron is the one most likely to have set it. Like the importer,
  the job needs nothing but the backup directory. When this node has no backup
  directory it does nothing, without a warning.

  ## Which node

  A backup directory is either shared by every node or one per host (#2218).
  Each node's heartbeat (`KilnCMS.Backups.Heartbeat`) gives its backup
  directory an id (`<BACKUP_DIR>/.kiln-dir-id`, `KilnCMS.Backups.DirId`) while
  this job is on and the directory already holds backups, and reports it in
  its beat (`KilnCMS.Backups.NodeBeat`); this job itself never creates one
  (#2789). The cron job (no args) then:

    * **syncs the fetching node's own directory in place**, with or without an
      id, so the node that fetched the job is covered every slot; and
    * **queues one job per other id** reported by a beat of the last
      10 minutes, judged on the database's clock (`"dir"` in the args). That
      job snoozes for 30 s on a node whose directory has another id, at most
      20 times (about ten minutes), then gives up for that slot as
      `StepWorker` does.

  A per-directory job goes to the directory's own queue, `backup_dir_<id>`,
  when a live node advertises it (`KilnCMS.Backups.DirQueues`, #2845), so
  only a node with that directory fetches it; a node without the directory
  that fetches one from `default` moves it there (same job,
  `{:snooze, 0}`). With no such queue it snoozes in `default` as above. One
  left waiting in a directory queue that no live node advertises for five
  minutes, or whose directory no live node reports for thirty, is canceled
  with the give-up line (`sweep_stranded/0`, from each heartbeat tick).

  On a shared volume every node reports the same id, so no job is queued and
  the in-place sync covers it. With a directory per host, each host is synced
  every slot its node fetches one of the ~21 releases of its routed job: the
  same assumption `StepWorker` makes. A directory with no id (no backup
  directory yet, one the app can't write, or this job turned off) is synced
  only in the slots its own node fetches the cron job. A node whose heartbeat
  stopped (the node is down) gets no job until it beats again.

  ## A backup directory that hangs (#3079)

  Every file operation on the backup directory (reading its id, and the
  sync itself) runs in a task under `KilnCMS.Backups.MarkerSyncIO`, which the
  job waits on: at most `dir_id_timeout_ms` (5 s by default, the heartbeat's
  setting) for the id, and `marker_sync_io_timeout_ms` (120 s by default) for
  the sync, both under `config :kiln_cms, KilnCMS.Backups`. A process blocked
  in a file operation on a hung mount can't be killed, so a task that takes
  longer is left running: the job logs a warning, emits
  `[:kiln_cms, :backups, :marker_sync, :timeout]` and gives up for the slot
  with `{:error, :backup_dir_unresponsive}`, so the Oban slot is free again.
  If the task finishes later, a line at info says how long it took, so a slow
  but healthy directory shows up as one. The job's own `timeout/1` is both
  waits plus a minute, so it outlasts them under any configuration; keep it
  well inside the Lifeline's rescue window.

  Tasks the job is still waiting on are not limited: the queue's concurrency
  bounds them, and a sync waiting its turn for the backup lock is normal.
  Abandoned ones are (`KilnCMS.Backups.MarkerSyncAbandoned`): while two that
  a job gave up on are still running, a job starts none and fails with
  `{:error, :backup_dir_io_busy}`, so a mount that stays hung can't pile up
  blocked tasks (each holds one of the VM's dirty I/O schedulers, which the
  heartbeat's id reads share). Jobs already waiting when the mount hung can
  each still leave one behind, so the limit is two plus those.

  A cron job whose own id read gives up still queues the jobs for the other
  directories, then fails without syncing its own. A per-directory job whose
  id read gives up (or can't start) treats its directory as not this node's
  and snoozes, as it does for any other id error, so another node with that
  directory can still pick it up.

  One known limit: the sync runs under the backup lock (`Chain.with_lock/1`,
  a cluster-wide advisory lock in a transaction). A task blocked on the
  directory inside that transaction keeps holding the lock, and the
  connection, until the file operation returns. In the meantime everything
  else that takes the lock (other syncs, in-app backup requests and steps,
  the heartbeat's lock sweep) blocks on the advisory lock until its query
  times out.

  ## Failures

  A failed import, an unreadable directory or history, or a lock that can't
  be taken writes and removes no marker; `Chain.sync_last_good/2` logs it with
  a `[:kiln_cms, :backups, :last_good, :failed]` event, and the job fails
  without retrying: the next slot runs the same sync. One attempt only.

  ## Uniqueness

  Every insert (the cron slot, `SyncHolds` and the per-directory jobs) is
  unique per directory, in any queue, while a job is waiting: `:available`,
  `:scheduled` (a snoozing job) or `:retryable`. A waiting job reads the schedules when it
  runs, so a second one would sync nothing new, and a slow or snoozing job
  never stacks up behind the next slot's.

  An `:executing` job does not count (#2932): it may have read the schedules
  before a change committed, so a change made while it runs queues one more
  job behind it. That job's sync waits on the backup lock (a waiting advisory
  lock, `Chain.with_lock/1`) until the running one is done, then reads the
  schedules afresh. So each directory normally has one running job and at
  most one waiting behind it (a per-directory job that snoozes while a
  fan-out inserts can briefly leave two waiting, which costs one redundant
  sync).

  While an in-app backup holds the lock, a sync returns `:busy` and writes
  nothing; the backup's finish step syncs the markers itself with the
  schedules as they are then. So a change made during a running in-app
  backup reaches the `.hold` markers when that backup succeeds (a failed one
  leaves it to the next slot).
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      # Not `:queue`: a per-directory job may be in `default` or its
      # directory's queue (#2845).
      fields: [:args, :worker],
      keys: [:dir],
      period: :infinity,
      # No :executing: a running job may have read the schedules before a
      # change committed (#2932, "Uniqueness" above).
      states: [:available, :scheduled, :retryable]
    ]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, DirQueues, MarkerSyncAbandoned}

  import Ecto.Query, only: [from: 2]

  require Logger

  @beat_window_s 600
  @affinity_snooze_s 30
  @affinity_max_snoozes 20
  @io KilnCMS.Backups.MarkerSyncIO
  @dir_id_timeout_ms 5_000
  @sync_timeout_ms 120_000
  @timeout_margin_ms 60_000
  @max_abandoned 2

  # Longer than both I/O waits (#3079), whatever they are configured to, so a
  # hung directory fails the job through `run_io/4`, with a reason, rather
  # than through Oban's timeout.
  @impl Oban.Worker
  def timeout(_job), do: io_wait_ms() + @timeout_margin_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dir" => dir_id}} = job) when is_binary(dir_id) do
    # Read in the job's process and handed to the tasks.
    dir = Backups.dir()

    cond do
      read_dir_id(dir) == {:ok, dir_id} ->
        sync_here(dir)

      DirQueues.route?(job, dir_id) ->
        case DirQueues.move(job, DirQueues.name(dir_id)) do
          :ok -> {:snooze, 0}
          :gone -> {:cancel, :superseded}
        end

      (job.meta["snoozed"] || 0) < @affinity_max_snoozes ->
        {:snooze, @affinity_snooze_s}

      true ->
        give_up_line(dir_id)
        {:cancel, :backup_dir_elsewhere}
    end
  end

  def perform(%Oban.Job{}) do
    with {:ok, ids} <- reported_dir_ids() do
      dir = Backups.dir()
      own_read = read_dir_id(dir)

      own =
        case own_read do
          {:ok, id} -> id
          {:error, _} -> nil
        end

      others = Enum.reject(ids, &(&1 == own))
      routable = routable_ids(others)
      Enum.each(others, &enqueue(&1, routable))

      # A directory that didn't answer for its id gets no sync this slot
      # (#3079): it would only hold up a second task.
      case own_read do
        {:error, reason} when reason in [:backup_dir_unresponsive, :backup_dir_io_busy] ->
          {:error, reason}

        _read ->
          sync_here(dir)
      end
    end
  end

  @doc """
  Whether the job runs on this deployment: `KILN_BACKUP_MARKER_SYNC_CRON`
  resolves to a cron expression (not `false`, blank or unparseable). The
  heartbeat creates backup-directory ids only while it does.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: KilnCMS.Application.cron_expression(:backup_marker_sync_cron) != nil

  # The directory ids the nodes' recent beats report, on the database's clock.
  # Fails closed: a refused or failed read is an error, never "no ids".
  defp reported_dir_ids do
    case Backups.list_live_node_beats(@beat_window_s,
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, beats} ->
        {:ok, beats |> Enum.map(& &1.dir_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()}

      {:error, error} ->
        Logger.warning(
          "Backup last-good marker sync skipped: couldn't read the node heartbeats " <>
            "(#{Exception.message(error)})"
        )

        {:error, {:node_beats, error.__struct__}}
    end
  end

  # The directories among `ids` whose queue a live node advertises (#2845),
  # from one read of the beats. None when routing is off, there are none,
  # or the beats can't be read (the jobs then snooze in `default`).
  defp routable_ids([]), do: MapSet.new()

  defp routable_ids(ids) do
    with true <- DirQueues.enabled?(),
         {:ok, statuses} <- DirQueues.statuses(ids) do
      for {id, :advertised} <- statuses, into: MapSet.new(), do: id
    else
      _ -> MapSet.new()
    end
  end

  # A conflict is a job for that directory still waiting from an earlier slot.
  defp enqueue(dir_id, routable) do
    opts = if MapSet.member?(routable, dir_id), do: [queue: DirQueues.name(dir_id)], else: []

    case %{"dir" => dir_id} |> new(opts) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Couldn't queue the last-good marker sync for backup directory #{dir_id} " <>
            "(#{inspect(reason)})"
        )
    end
  end

  defp give_up_line(dir_id) do
    Logger.warning(
      "Backup last-good marker sync for backup directory #{dir_id} gave up: " <>
        "no node with that directory picked it up"
    )
  end

  @doc """
  Cancel the per-directory jobs left waiting in a directory queue no node
  runs (#2845): one whose directory a live node (180 s) reports but none
  advertises its queue, after five minutes, and one whose directory no live
  node reports, after thirty. Each logs the give-up line once per directory.
  Beats that can't be read cancel nothing. The heartbeat's sweep runs it.
  Returns how many it canceled.
  """
  @spec sweep_stranded() :: non_neg_integer()
  def sweep_stranded do
    with [_ | _] = waiting <- DirQueues.waiting(inspect(__MODULE__)),
         {:ok, statuses} <-
           waiting |> Enum.map(& &1.dir_id) |> Enum.uniq() |> DirQueues.statuses() do
      stranded =
        Enum.filter(waiting, &(DirQueues.verdict(statuses[&1.dir_id], &1.waited_s) != :leave))

      cancel_stranded(stranded)
    else
      _ -> 0
    end
  end

  defp cancel_stranded([]), do: 0

  defp cancel_stranded(stranded) do
    ids = Enum.map(stranded, & &1.id)

    {:ok, canceled} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where: j.id in ^ids and j.state in ["available", "scheduled", "retryable"]
        )
      )

    stranded |> Enum.map(& &1.dir_id) |> Enum.uniq() |> Enum.each(&give_up_line/1)
    canceled
  end

  defp read_dir_id(dir) do
    reader = Keyword.get(backups_env(), :marker_sync_dir_reader, &DirId.current/1)

    run_io(:dir_id, dir, dir_id_timeout_ms(), fn -> reader.(dir) end)
  end

  defp sync_here(dir) do
    syncer = Keyword.get(backups_env(), :marker_sync_syncer, &sync/1)

    run_io(:sync, dir, sync_timeout_ms(), fn -> syncer.(dir) end)
  end

  defp sync(dir) do
    if File.dir?(dir) do
      case Chain.sync_last_good(dir) do
        {:ok, _last_good} -> :ok
        :busy -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  # `fun` in a task under `KilnCMS.Backups.MarkerSyncIO`, waited on for
  # `timeout` ms (see "A backup directory that hangs"). The task carries this
  # process in `$callers`. One that takes longer is left running, since it
  # can't be killed while blocked in a file operation, and handed to
  # `MarkerSyncAbandoned`.
  defp run_io(phase, dir, timeout, fun) do
    if MarkerSyncAbandoned.count() >= @max_abandoned do
      busy(phase, dir)
    else
      task = Task.Supervisor.async_nolink(@io, fun)

      case Task.yield(task, timeout) || Task.ignore(task) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:crashed, reason}}
        nil -> unresponsive(phase, dir, timeout, task.pid)
      end
    end
  end

  defp busy(phase, dir) do
    Logger.warning(
      "Backup last-good marker sync didn't start the #{describe(phase)} of #{dir}: " <>
        "#{@max_abandoned} earlier ones it gave up on are still running (a hung mount?)"
    )

    {:error, :backup_dir_io_busy}
  end

  defp unresponsive(phase, dir, timeout, pid) do
    :ok = MarkerSyncAbandoned.abandon(pid, phase, dir)

    :telemetry.execute(
      [:kiln_cms, :backups, :marker_sync, :timeout],
      %{count: 1, waited_ms: timeout},
      %{phase: phase}
    )

    Logger.warning(
      "Backup last-good marker sync: the #{describe(phase)} of the backup directory #{dir} " <>
        "took more than #{timeout} ms (a hung mount?). Giving up for this slot; the " <>
        "#{describe(phase)} is left running."
    )

    {:error, :backup_dir_unresponsive}
  end

  defp describe(:dir_id), do: "id read"
  defp describe(:sync), do: "marker sync"

  @doc false
  # The longest the job waits on the backup directory: the id read, then the
  # sync. `timeout/1` must be longer.
  @spec io_wait_ms() :: pos_integer()
  def io_wait_ms, do: dir_id_timeout_ms() + sync_timeout_ms()

  # `config :kiln_cms, KilnCMS.Backups`: `dir_id_timeout_ms:` (shared with the
  # heartbeat's id read), `marker_sync_io_timeout_ms:`, and
  # `marker_sync_dir_reader:` and `marker_sync_syncer:` (one-argument
  # functions, tests only).
  defp dir_id_timeout_ms, do: Keyword.get(backups_env(), :dir_id_timeout_ms, @dir_id_timeout_ms)

  defp sync_timeout_ms,
    do: Keyword.get(backups_env(), :marker_sync_io_timeout_ms, @sync_timeout_ms)

  defp backups_env, do: Application.get_env(:kiln_cms, KilnCMS.Backups, [])
end
