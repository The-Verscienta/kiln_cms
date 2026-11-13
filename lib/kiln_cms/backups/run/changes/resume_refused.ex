defmodule KilnCMS.Backups.Run.Changes.ResumeRefused do
  @moduledoc """
  The `:note_resume_refused` action of `KilnCMS.Backups.Run` (#2539): a resume
  that was requested but could not run says so on the run's row, which is the
  only place the History page shows it (`run.error`).

  The run keeps its status: a failed or canceled run stays failed or canceled,
  and so stays resumable. The one exception is a `running` run that is stale
  (`KilnCMS.Backups.run_stale?/2`): its job is gone, the stale-run sweep would
  fail it on its next pass anyway, and failing it here makes the refusal
  visible at once. Its previous-error line is then the sweep's own
  "Interrupted: ..." line.

  The error becomes `"Resume refused: <reason>"`, then the previous error on
  the next line. A previous error that already starts with a refusal loses that
  first line, so refusals never stack and the original failure is kept. The
  log gains the same line.

  The UPDATE's WHERE requires an in-app run with the status the caller loaded
  (and, for a `running` one, still stale), so a live run, an imported run, or
  a run another chain re-opened meanwhile is never touched: the caller gets an
  `Ash.Error.Changes.StaleRecord` error. A succeeded or skipped run is refused
  with an error on `status`.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias KilnCMS.Backups

  @prefix "Resume refused: "
  @interrupted "Interrupted: the job was killed or the node stopped"

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :reason) do
      # The action's own `allow_nil? false` reports a missing reason.
      reason when is_binary(reason) -> refuse(changeset, changeset.data, reason)
      _missing -> changeset
    end
  end

  defp refuse(changeset, run, reason) do
    now = DateTime.utc_now()

    case run.status do
      status when status in [:failed, :canceled] ->
        changeset
        |> Ash.Changeset.filter(Ash.Expr.expr(origin == :app and status == ^status))
        |> note(reason, run.error, now)

      :running ->
        %{stale: stale} = Backups.resume_cutoffs(now)

        changeset
        |> Ash.Changeset.filter(
          Ash.Expr.expr(
            origin == :app and status == :running and started_at < ^stale and
              updated_at < ^stale
          )
        )
        |> Ash.Changeset.force_change_attribute(:status, :failed)
        |> Ash.Changeset.force_change_attribute(:finished_at, now)
        |> note(reason, run.error || @interrupted, now)

      _other ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "has no resume to refuse: only a failed, canceled or interrupted run has"
        )
    end
  end

  defp note(changeset, reason, previous, now) do
    message = @prefix <> reason
    entry = %{at: now, level: :error, step: "resume", message: message}

    changeset
    |> Ash.Changeset.force_change_attribute(:error, error(message, previous))
    |> Ash.Changeset.force_change_attribute(:log, (changeset.data.log || []) ++ [entry])
  end

  defp error(message, nil), do: message

  defp error(message, previous) do
    previous =
      if String.starts_with?(previous, @prefix) do
        previous |> String.split("\n", parts: 2) |> Enum.at(1)
      else
        previous
      end

    case previous do
      blank when blank in [nil, ""] -> message
      previous -> message <> "\n" <> previous
    end
  end
end
