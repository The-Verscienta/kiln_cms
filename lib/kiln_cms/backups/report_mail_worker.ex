defmodule KilnCMS.Backups.ReportMailWorker do
  @moduledoc """
  Sends one backup report email (#2229) to one platform admin, queued by
  `KilnCMS.Backups.ReportWorker`.

  The job carries ids only: the run, the `finished_at` of the outcome it
  reports, and the recipient. Everything else is read when it runs, because
  a mail job can wait hours for a retry:

    * the run must still have that outcome, or be the failure it was before
      a resume (`ReportWorker.current_run/2`);
    * the recipient must still be mailable (`KilnCMS.Accounts.mail_recipient/1`:
      not erased, an address left), still a platform admin
      (`KilnCMS.Accounts.RoleGrant.effective_role/1` on the account as read
      now, through `KilnCMS.Accounts.Scoping.platform_admin?/1`), and must
      still want it (`ReportWorker.mail?/2`, by `User.notify_on_backup` now);
    * the address must not be on the instance-wide suppression list
      (`KilnCMS.Mail.check_suppression/2`).

  A skip finishes the job with `:ok`, logged with the job id and a reason,
  never the address. A read that fails, a refused one included, fails the
  job, which retries.

  Sent through the **instance** relay, as the platform security alerts are:
  the backups are the instance's, and no site's relay setting should decide
  whether their failures are heard. Unique on the run, the `finished_at` and
  the recipient, in every state, so a fan-out that runs twice queues one
  mail. Twenty attempts on the mail backoff, as `ReportWorker`.
  """
  use Oban.Worker,
    queue: :mail,
    max_attempts: 20,
    unique: [keys: [:run_id, :finished_at, :user_id], period: :infinity, states: :all]

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Backups.{Report, ReportMail, ReportWorker}
  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "user_id" => user_id} = args} = job)
      when is_binary(run_id) and is_binary(user_id) do
    with {:ok, run, opts} <- ReportWorker.current_run(run_id, args["finished_at"]),
         {:ok, user} <- Accounts.mail_recipient(user_id),
         :ok <- platform_admin(user),
         report = Report.build(run, ReportWorker.schedules(run), opts),
         :ok <- wanted(user, report),
         :ok <- Mail.check_suppression(to_string(user.email)) do
      user
      |> ReportMail.build(report)
      # Keyed on the job id, so every retry of this job carries the same
      # Message-ID.
      |> Mail.ensure_message_id("backup-report-#{job.id}")
      |> Mail.deliver_for_worker()
    else
      {:skip, reason} -> skip(job, reason)
      {:error, error} -> {:error, error}
    end
  end

  def perform(%Oban.Job{id: id}) do
    Logger.info("backup report mail job #{id}: no run or recipient in the job, nothing sent")
    :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # Same per-attempt ceiling as the other mail workers (`Mail.attempt_timeout/0`).
  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()

  defp platform_admin(user),
    do: if(Scoping.platform_admin?(user), do: :ok, else: {:skip, :not_platform_admin})

  defp wanted(user, report),
    do: if(ReportWorker.mail?(user, report), do: :ok, else: {:skip, :muted})

  # A fixed reason and the job id: never the address.
  defp skip(%Oban.Job{id: id}, reason) do
    Logger.info("backup report mail job #{id} not sent: #{reason}")
    :ok
  end
end
