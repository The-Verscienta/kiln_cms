defmodule KilnCMS.Backups.Run.Changes.AfterOutcome do
  @moduledoc """
  Enqueues the backup report of a run's outcome (#2229) in the write that
  records it: a transactional outbox (ADR 0094).

  On every action that can give a run its outcome (`:finish`, `:fail`,
  `:skip`, `:cancel`, `:cancel_resume`, `:note_resume_refused`, `:import` and
  `:reevaluate_interrupted`), an `after_action` hook inserts one
  `KilnCMS.Backups.ReportWorker` job with the run's id and `finished_at`,
  when the status the write leaves is terminal (`succeeded`, `failed`,
  `skipped` or `canceled`) and new for the row: a changed status, or a
  changed `finished_at` (a re-evaluated import that is still `failed`). The insert is one plain
  INSERT on the action's own connection, inside its transaction, so:

    * the job exists exactly when the outcome commits. A write that rolls
      back (a Cancel refused inside the backup lock's transaction, an outer
      transaction that aborts) leaves no job, and a node that dies after the
      COMMIT can't lose it;
    * an insert that fails fails the write with it: the report and the
      outcome commit or fail together, as `KilnCMS.Security.Changes.Record`
      in `mode: :in_transaction` does for the audit event of a Cancel;
    * a second terminal writer racing the first gets `StaleRecord` from the
      action's own filter (`status == :running`, `OwnChain`), so its hook
      never runs, and a write that leaves the status as it was (a refused
      resume or a canceled resume of a `failed` run) enqueues nothing.

  The job is not `unique`: Oban's uniqueness check takes a try-lock that can
  drop the insert, and the outbox already gives one job per committed
  terminal write. What makes the reports themselves idempotent is the mail
  job's own uniqueness and the collapsing bell row (`ReportWorker`).

  A failed run's job is scheduled #{60} seconds out: the record that adds an
  interrupted run's log and destinations (`:record_interrupted`) usually
  lands in that time, and the report reads the run when it runs.

  ## Imported runs

  Cron's runs are reported too (owner decision, 2026-11-27): an `:import`
  that inserts a terminal row, and an `:reevaluate_interrupted` that changes
  one's outcome. An import's upsert that hit an existing stamp returns that
  row, not the one this changeset built, so the hook compares ids and stays
  quiet. A stamp older than #{48} hours is imported without a report: the
  first import of a directory full of old backups (a fresh install pointed at
  an existing directory, a restored database) would otherwise mail one
  report per backup ever taken.

  ## Remembering a failure

  The same change sets `last_failed_at` on a write that leaves the run
  `failed`: the `finished_at` of that failure, which a resume keeps. A run
  that succeeds with it set had a failure reported and has recovered, and
  `ReportWorker` says so (`KilnCMS.Backups.Report.recovered?/1`).
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Backups.ReportWorker

  @terminal [:succeeded, :failed, :skipped, :canceled]
  @import_window_s 48 * 3600

  @doc "The terminal statuses a report is enqueued for."
  @spec terminal() :: [atom()]
  def terminal, do: @terminal

  @doc "How old (in seconds) an imported run may be and still be reported."
  @spec import_window_s() :: pos_integer()
  def import_window_s, do: @import_window_s

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> remember_failure()
    |> Ash.Changeset.after_action(&enqueue/2)
  end

  # Only when this write is what makes the run `failed`: the status the
  # action set (`set_attribute`, or a change that forced it) is applied by
  # now, and the hook below reads the same.
  defp remember_failure(changeset) do
    with :failed <- Ash.Changeset.get_attribute(changeset, :status),
         true <-
           changeset.action_type == :create or changeset.data.status != :failed or
             Ash.Changeset.changing_attribute?(changeset, :finished_at) do
      at = Ash.Changeset.get_attribute(changeset, :finished_at) || DateTime.utc_now()
      Ash.Changeset.force_change_attribute(changeset, :last_failed_at, at)
    else
      _not_a_new_failure -> changeset
    end
  end

  defp enqueue(changeset, run) do
    if reportable?(changeset, run) do
      case run |> ReportWorker.new_for() |> Oban.insert() do
        {:ok, _job} ->
          {:ok, run}

        {:error, error} ->
          Logger.error("Backup report of #{run.stamp} not enqueued: #{inspect(error)}")

          :telemetry.execute([:kiln_cms, :backups, :report, :not_enqueued], %{count: 1}, %{
            status: run.status
          })

          {:error, error}
      end
    else
      {:ok, run}
    end
  end

  defp reportable?(changeset, run) do
    run.status in @terminal and new_outcome?(changeset, run) and recent?(run)
  end

  # A create is new when it inserted the row it built: an `:import` upsert on
  # an existing stamp hands back that row instead.
  defp new_outcome?(%{action_type: :create} = changeset, run),
    do: Ash.Changeset.get_attribute(changeset, :id) == run.id

  # An update is new when it changed the status, or the `finished_at` of
  # the outcome: a re-evaluated Interrupted import that is still `failed`
  # (another error, another time) is a new failure.
  defp new_outcome?(changeset, run),
    do: changeset.data.status != run.status or changeset.data.finished_at != run.finished_at

  defp recent?(%{origin: :imported} = run) do
    at = run.finished_at || run.started_at
    is_struct(at, DateTime) and DateTime.diff(DateTime.utc_now(), at) <= @import_window_s
  end

  defp recent?(_run), do: true
end
