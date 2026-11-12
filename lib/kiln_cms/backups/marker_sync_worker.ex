defmodule KilnCMS.Backups.MarkerSyncWorker do
  @moduledoc """
  Keeps the last-good markers (`kiln-<stamp>.good`) in step for deployments
  whose backups come from host cron (#2554).

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
  Only an in-app backup creates `<BACKUP_DIR>/.kiln-dir-id`
  (`KilnCMS.Backups.DirId`); `scripts/backup.sh` never does, and this job
  never creates one either. So the cron job (no args) routes by what the
  nodes' heartbeats (`KilnCMS.Backups.NodeBeat`, beaten in the last
  10 minutes) report:

    * **No node reports a directory id**, the usual cron-only deployment: the
      sync runs on whichever node fetched the job. On a shared directory that
      covers it. With a directory per host and no ids, only the fetching
      node's directory is synced in that slot, and another node's in a later
      slot it happens to fetch; nothing can tell the directories apart.
    * **Some nodes report an id**: one job per id (`"dir"` in the args), which
      snoozes for 30 s on a node whose directory has another id, at most
      20 times (about ten minutes), then gives up for that slot as
      `StepWorker` does. The fetching node also syncs its own directory when
      that directory has no id, since no routed job can reach it.

  ## Failures

  A failed import, an unreadable directory or history, or a lock that can't
  be taken writes and removes no marker; `Chain.sync_last_good/2` logs it with
  a `[:kiln_cms, :backups, :last_good, :failed]` event, and the job fails
  without retrying: the next slot runs the same sync. One attempt only, and
  unique per directory while a job is live, so a slow or snoozing job never
  stacks up behind the next slot's.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      keys: [:dir],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId}

  require Logger

  @beat_window_s 600
  @affinity_snooze_s 30
  @affinity_max_snoozes 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dir" => dir_id}} = job) when is_binary(dir_id) do
    cond do
      DirId.current() == {:ok, dir_id} ->
        sync_here()

      (job.meta["snoozed"] || 0) < @affinity_max_snoozes ->
        {:snooze, @affinity_snooze_s}

      true ->
        Logger.warning(
          "Backup last-good marker sync for backup directory #{dir_id} gave up: " <>
            "no node with that directory picked it up"
        )

        {:cancel, :backup_dir_elsewhere}
    end
  end

  def perform(%Oban.Job{}) do
    with {:ok, ids} <- reported_dir_ids() do
      Enum.each(ids, &enqueue/1)
      if ids == [] or DirId.current() == {:error, :enoent}, do: sync_here(), else: :ok
    end
  end

  # The directory ids the nodes' recent beats report. Fails closed: a refused
  # or failed read is an error, never "no ids".
  defp reported_dir_ids do
    cutoff = DateTime.add(DateTime.utc_now(), -@beat_window_s, :second)

    case Backups.list_node_beats(
           query: [filter: [beat_at: [greater_than: cutoff]]],
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

  # A conflict is a job for that directory still live from an earlier slot.
  defp enqueue(dir_id) do
    case %{"dir" => dir_id} |> new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Couldn't queue the last-good marker sync for backup directory #{dir_id} " <>
            "(#{inspect(reason)})"
        )
    end
  end

  defp sync_here do
    dir = Backups.dir()

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
end
