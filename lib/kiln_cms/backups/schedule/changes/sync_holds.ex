defmodule KilnCMS.Backups.Schedule.Changes.SyncHolds do
  @moduledoc """
  After a schedule is created, changed or deleted and the change has
  committed, queue a `KilnCMS.Backups.MarkerSyncWorker` sync (#2219), so the
  `.hold` markers `scripts/backup.sh prune` reads catch up with the new keep
  rules now rather than at the next backup or the next 15-minute slot.

  Nothing is queued when the marker sync is turned off
  (`KILN_BACKUP_MARKER_SYNC_CRON=false`), or when one is already waiting
  (the worker is unique while a job is available, scheduled or retryable;
  that job reads the schedules when it runs). A job that is already running
  does not stop the insert (#2932): it may have read the schedules before
  this change, so the new job queues behind it, waits for the backup lock it
  holds, and reads the committed change. If an in-app backup holds the lock
  instead, the job snoozes until the backup releases it, then syncs, however
  the backup ended (#2985, `MarkerSyncWorker.schedule_change_job/0`). A
  failed insert is logged and never fails the action: the next slot or
  backup syncs the markers anyway.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.MarkerSyncWorker

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, _record} = result ->
        enqueue()
        result

      _changeset, error ->
        error
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp enqueue do
    if MarkerSyncWorker.enabled?() do
      case Oban.insert(MarkerSyncWorker.schedule_change_job()) do
        {:ok, _job} -> :ok
        {:error, reason} -> not_queued(reason)
      end
    end
  rescue
    # The schedule change has committed: a database error inserting the job
    # must not make the caller think it didn't.
    error -> not_queued(error.__struct__)
  end

  defp not_queued(reason) do
    Logger.warning(
      "Couldn't queue the backup marker sync after a schedule change (#{inspect(reason)})"
    )
  end
end
