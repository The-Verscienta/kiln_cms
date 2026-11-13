defmodule KilnCMS.Backups.Run.Changes.Resume do
  @moduledoc """
  The guard and bookkeeping of `KilnCMS.Backups.Run`'s `:resume` action (#2218).

  A run may be resumed only if `KilnCMS.Backups.run_resumable?/2` says so: an
  in-app run that `failed` or was `canceled`, or one still `running` that has shown no sign of
  life for longer than the worker's timeout plus grace (its job is gone). A
  `succeeded`, `skipped` or imported run, and a `running` one that is still being
  written to, are refused with an error on `status`; the caller never falls back
  to a fresh run.

  That check reads the loaded struct, so it alone can't stop two callers that
  loaded the same run from both re-opening it (#2421). The guard is therefore
  re-checked in the UPDATE's WHERE: the row must still be an in-app run that is
  `failed`, `canceled` long enough ago for the Cancel to have settled (#2538),
  or `running` with both `started_at` and `updated_at` before the stale cutoff
  (`KilnCMS.Backups.resume_cutoffs/1`). The caller that loses gets an
  `Ash.Error.Changes.StaleRecord` error, and the row keeps the winner's
  `chain_id`.

  The Cancel cooldown is not part of the early check: `run_resumable?/2` is
  what shows the Resume button, which stays visible, and
  `KilnCMS.Backups.resumable_run/3` refuses a click inside the window with
  `{:canceled_recently, seconds}`. The filter is the backstop for a caller
  that skipped that.

  On success it appends a `resume` log line, naming the previous outcome. The
  attributes it clears (`finished_at`, `error`) and the status it sets are the
  action's own `set_attribute` changes.
  """
  use Ash.Resource.Change

  require Ash.Expr

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

      changeset
      |> Ash.Changeset.force_change_attribute(:log, (run.log || []) ++ [entry])
      |> still_resumable(entry.at)
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "can't be resumed: only a failed, interrupted or canceled in-app backup can"
      )
    end
  end

  # The same guard as `run_resumable?/2`, in the UPDATE's WHERE (#2421), plus
  # the Cancel cooldown (#2538). A canceled row with no `finished_at` passes,
  # as in `Backups.resumable_run/3`.
  defp still_resumable(changeset, now) do
    %{stale: stale, canceled: canceled} = Backups.resume_cutoffs(now)

    Ash.Changeset.filter(
      changeset,
      Ash.Expr.expr(
        origin == :app and
          (status == :failed or
             (status == :canceled and (is_nil(finished_at) or finished_at <= ^canceled)) or
             (status == :running and started_at < ^stale and updated_at < ^stale))
      )
    )
  end
end
