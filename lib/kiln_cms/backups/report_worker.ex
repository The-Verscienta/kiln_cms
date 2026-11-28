defmodule KilnCMS.Backups.ReportWorker do
  @moduledoc """
  Fans a backup run's report out (#2229): the bell rows, and one
  `KilnCMS.Backups.ReportMailWorker` job per platform admin who wants the
  email.

  Enqueued by the write that gave the run its outcome, in its transaction
  (`KilnCMS.Backups.Run.Changes.AfterOutcome`, ADR 0094). The job carries
  the run's id and the `finished_at` of that outcome, nothing else, and
  reads the run back when it runs:

    * a run that is gone, has no outcome to report (still `running`), or
      whose `finished_at` is not the job's (it has a newer outcome, which
      has its own job) sends nothing and finishes;
    * except a failure that was resumed before its report ran (the job of a
      failed run waits a minute): when the run's `last_failed_at` is the
      job's `finished_at`, the run is reported as the failure it was, however
      the resume has gone since (`current_run/2`). The resume cleared the
      run's error, so the report shows the failure's logged error lines and
      says the run was resumed since;
    * the run is read as `KilnCMS.Backups.system/0` with
      `authorize_with: :error`: a refused read fails the job, which retries.
      It is never taken for "gone".

  Then, for every platform admin (`KilnCMS.Accounts.Scoping.platform_admins/0`):

    * a failed or partly off-site run writes a bell row
      (`:backup_failed`, `:backup_partly_offsite`) for each, whatever their
      email preference: the preference mutes the email only. The rows
      collapse: while one is unread it is refreshed to say this run
      (`KilnCMS.Notifications.record_in_app_refreshing/1`);
    * a recovered run (`KilnCMS.Backups.Report.recovered?/1`) marks each
      admin's unread `:backup_failed` row about this run read;
    * a mail job is queued for each admin `KilnCMS.Notifications.backup_mail?/2`
      admits for the run's class, and, for a recovered run, for each admin a
      failure report of this run was queued for (`mail?/2`): who got the
      failure hears it recovered. A recovery whose failure has not been
      fanned out yet waits for it (the job snoozes). Unique on the run, the
      `finished_at` and the admin, so a job that runs twice queues one mail
      each;
    * one import pass can record many cron runs (a directory imported for
      the first time, or after an outage): an imported run that
      succeeded or was skipped is not reported when a newer imported run
      has an outcome, so the pass mails about its newest run only. A failed
      or partly off-site import, and a recovered one, is reported whatever
      is newer.

  The job of a failed run is scheduled #{60} seconds out
  (`new_for/1`), so the record that completes an interrupted run's log
  (`:record_interrupted`) has usually landed before the report reads it.

  Not `unique` itself: see `Run.Changes.AfterOutcome`. Twenty attempts on
  the mail backoff (`KilnCMS.Mail.backoff_seconds/1`, about five days), so a
  long rolling deploy, in which an older node with no such worker picks the
  job up and fails it, does not discard it.
  """
  use Oban.Worker, queue: :mail, max_attempts: 20

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Report, ReportMailWorker, Run}
  alias KilnCMS.Mail
  alias KilnCMS.Notifications

  @failed_delay_s 60
  @recovery_snooze_s 60
  @pending ~w(scheduled available executing retryable)
  @queued ~w(scheduled available executing retryable completed)

  @doc "The job reporting `run`'s outcome, as the write that recorded it enqueues it."
  @spec new_for(Run.t()) :: Oban.Job.changeset()
  def new_for(%Run{} = run) do
    opts = if run.status == :failed, do: [schedule_in: @failed_delay_s], else: []
    new(args(run), opts)
  end

  @doc "The job's arguments: ids only (see `KilnCMS.Jobs.PrivateArgs`)."
  @spec args(Run.t()) :: map()
  def args(%Run{id: id, finished_at: finished_at}),
    do: %{"run_id" => id, "finished_at" => iso(finished_at)}

  @doc """
  The run a report job names: `{:ok, run, opts}` when the job's outcome is
  still to report, with the `KilnCMS.Backups.Report.build/3` options to
  report it with; `{:skip, reason}` when it is not; `{:error, error}` when
  the run couldn't be read. Shared with `KilnCMS.Backups.ReportMailWorker`.

  A run whose `finished_at` is the job's has that outcome. A run whose
  `last_failed_at` is the job's `finished_at` was resumed after that
  failure (and may have ended again since): it is handed back as the
  failure, `status: :failed` at that time, with `resumed_since?: true`.
  """
  @spec current_run(String.t(), String.t() | nil) ::
          {:ok, Run.t(), keyword()} | {:skip, atom()} | {:error, term()}
  def current_run(run_id, finished_at) when is_binary(run_id) do
    case Backups.get_run(run_id,
           actor: Backups.system(),
           authorize_with: :error,
           not_found_error?: false
         ) do
      {:ok, nil} ->
        {:skip, :run_gone}

      {:ok, %Run{} = run} ->
        as_of(run, finished_at)

      {:error, error} ->
        {:error, error}
    end
  end

  defp as_of(run, finished_at) do
    cond do
      iso(run.finished_at) == finished_at and Report.classify(run) != nil ->
        {:ok, run, []}

      is_binary(finished_at) and iso(run.last_failed_at) == finished_at ->
        {:ok, %{run | status: :failed, finished_at: run.last_failed_at}, [resumed_since?: true]}

      is_nil(Report.classify(run)) ->
        {:skip, :no_outcome}

      true ->
        {:skip, :superseded}
    end
  end

  @doc "The schedules `run` ran for that still exist, read as the backup system actor."
  @spec schedules(Run.t()) :: [Backups.Schedule.t()]
  def schedules(%Run{schedule_ids: []}), do: []

  def schedules(%Run{schedule_ids: ids}) do
    require Ash.Query

    query = Ash.Query.filter(Backups.Schedule, id in ^ids)
    Backups.list_backup_schedules!(actor: Backups.system(), authorize_with: :error, query: query)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id} = args} = job) when is_binary(run_id) do
    with {:ok, run, opts} <- current_run(run_id, args["finished_at"]),
         :ok <- newest_import(run),
         report = Report.build(run, schedules(run), opts),
         :ok <- failure_fanned_out(report, run) do
      fan_out(run, report)
    else
      {:skip, reason} -> skip(job, reason)
      {:snooze, _seconds} = snooze -> snooze
      {:error, error} -> {:error, error}
    end
  end

  def perform(%Oban.Job{id: id}) do
    Logger.info("backup report job #{id}: no run in the job, nothing sent")
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # The flood guard (see the moduledoc): an imported run that succeeded or
  # was skipped, when a newer imported run has an outcome.
  defp newest_import(%Run{origin: :imported} = run) do
    if Report.classify(run) in [:succeeded, :skipped] and not Report.recovered?(run) and
         newer_import?(run),
       do: {:skip, :newer_import},
       else: :ok
  end

  defp newest_import(_run), do: :ok

  defp newer_import?(%Run{started_at: started_at, id: id}) do
    require Ash.Query

    query =
      Run
      |> Ash.Query.filter(
        origin == :imported and status in [:succeeded, :failed, :skipped, :canceled] and
          started_at > ^started_at and id != ^id
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(1)

    Backups.list_runs!(actor: Backups.system(), authorize_with: :error, query: query) != []
  end

  # A recovery is reported to whoever its failure was mailed to, so that
  # failure's fan-out must have run first: the failure's job waits a minute,
  # and a quick resume can finish inside it.
  defp failure_fanned_out(%Report{recovered?: true}, %Run{} = run) do
    pending =
      KilnCMS.Repo.exists?(
        from(j in Oban.Job,
          where:
            j.worker == "KilnCMS.Backups.ReportWorker" and j.state in @pending and
              fragment("?->>'run_id'", j.args) == ^run.id and
              fragment("?->>'finished_at'", j.args) == ^iso(run.last_failed_at)
        )
      )

    if pending, do: {:snooze, @recovery_snooze_s}, else: :ok
  end

  defp failure_fanned_out(_report, _run), do: :ok

  defp fan_out(run, report) do
    admins = Scoping.platform_admins()

    bell(report, admins)

    if report.recovered? do
      Enum.each(admins, &Notifications.mark_backup_recovered(&1, run.id))
    end

    for admin <- admins, mail?(admin, report) do
      %{"run_id" => run.id, "finished_at" => iso(run.finished_at), "user_id" => admin.id}
      |> ReportMailWorker.new()
      |> Oban.insert!()
    end

    :ok
  end

  @doc """
  Whether `user` is emailed `report`: by their preference for its class
  (`Notifications.backup_mail?/2`), or, for a recovery, when a failure
  report of the same run was queued for them (a `ReportMailWorker` job for
  an earlier outcome of the run, not canceled or discarded) and they still
  want failure mail: an admin who chose Off since hears nothing more.
  Finished jobs are pruned after a week, so a recovery later than that is
  mailed only by preference.
  """
  @spec mail?(map(), Report.t()) :: boolean()
  def mail?(user, %Report{} = report) do
    Notifications.backup_mail?(user, report.class) or
      (report.recovered? and Notifications.backup_mail?(user, :failed) and
         failure_mailed?(user, report))
  end

  defp failure_mailed?(%{id: user_id}, %Report{run_id: run_id, finished_at: finished_at}) do
    KilnCMS.Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Backups.ReportMailWorker" and j.state in @queued and
            fragment("?->>'run_id'", j.args) == ^run_id and
            fragment("?->>'user_id'", j.args) == ^user_id and
            fragment("?->>'finished_at'", j.args) != ^iso(finished_at)
      )
    )
  end

  defp failure_mailed?(_user, _report), do: false

  defp bell(%Report{class: class} = report, admins) when class in [:failed, :partial] do
    event = if class == :failed, do: :backup_failed, else: :backup_partly_offsite
    org_id = Accounts.default_org_id()

    for admin <- admins do
      Notifications.record_in_app_refreshing(%{
        org_id: org_id,
        user_id: admin.id,
        event: event,
        content_type: Notifications.platform_backups_content_type(),
        content_id: org_id,
        title: String.slice(report.site_name, 0, 200),
        excerpt: Report.excerpt(report),
        details: Report.details(report)
      })
    end
  end

  defp bell(_report, _admins), do: []

  # A fixed reason and the job id: never an address.
  defp skip(%Oban.Job{id: id}, reason) do
    Logger.info("backup report job #{id} not sent: #{reason}")
    :ok
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
