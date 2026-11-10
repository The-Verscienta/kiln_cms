defmodule KilnCMS.Backups.Run.Changes.Resume do
  @moduledoc """
  The guard and bookkeeping of `KilnCMS.Backups.Run`'s `:resume` action (#2218).

  A run may be resumed only if `KilnCMS.Backups.run_resumable?/2` says so: an
  in-app run that `failed` or was `canceled`, or one still `running` that has shown no sign of
  life for longer than the worker's timeout plus grace (its job is gone). A
  `succeeded`, `skipped` or imported run, and a `running` one that is still being
  written to, are refused with an error on `status`; the caller never falls back
  to a fresh run.

  On success it appends a `resume` log line, naming the previous outcome. The
  attributes it clears (`finished_at`, `error`) and the status it sets are the
  action's own `set_attribute` changes.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups

  @impl true
  def change(changeset, _opts, _context) do
    run = changeset.data

    if Backups.run_resumable?(run) do
      previous =
        case run.status do
          :failed -> "failed"
          :canceled -> "canceled"
          _running -> "interrupted"
        end

      entry = %{
        at: DateTime.utc_now(),
        level: :info,
        step: "resume",
        message: "Resuming a #{previous} backup from the files already written"
      }

      Ash.Changeset.force_change_attribute(changeset, :log, (run.log || []) ++ [entry])
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "can't be resumed: only a failed, interrupted or canceled in-app backup can"
      )
    end
  end
end
