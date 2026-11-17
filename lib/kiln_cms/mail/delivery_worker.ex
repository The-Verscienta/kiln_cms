defmodule KilnCMS.Mail.DeliveryWorker do
  @moduledoc """
  Delivers one queued email to one recipient.

  Enqueued by `KilnCMS.Mail.enqueue!/1` (one job per recipient). Rebuilds the
  Swoosh email from the job's sealed args (`KilnCMS.Mail.open_args/1`) and
  delivers it via `KilnCMS.Mail.deliver_for_worker/2`: a permanent (5xx) reject
  of the message cancels the job; transient failures, and the relay refusing
  our AUTH, TLS or sender, raise and retry on the greylist-aware backoff.

  Once the job is finished — delivered, cancelled, or failing its last attempt
  — the message is dropped from its args (`KilnCMS.Mail.forget_body/1`, #1843):
  a password reset's link has no business sitting in `oban_jobs` for the week
  until the Pruner deletes the row.

  ## Account mail is checked when it is sent (#3035)

  A job can wait hours for a retry, and the account it was queued for can be
  erased meanwhile. Account mail names its account (`"user_id"`), and is sent
  only while that account still exists, is not erased, and holds the address
  the job is addressed to (`KilnCMS.Accounts.mail_recipient/1`). Otherwise the
  job drops its recipient and message (`KilnCMS.Mail.forget_message/1`) and
  completes: nothing went wrong, so it is not a delivery failure on
  /editor/mail. A job erasure withheld (`KilnCMS.Mail.withhold_pending/2`,
  `"withheld"`) completes the same way. The log line names the job and the
  reason, never the address. An account that cannot be read retries.

  A job with a `null` `"user_id"` is mail to an address with no account behind
  it (an invitation, a newsletter confirmation), and a job with no
  `"user_id"` key was queued by a release before #3035: both are sent as
  before.
  """
  use Oban.Worker, queue: :mail, max_attempts: 8

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"withheld" => reason}} = job) do
    Logger.info("Mail job #{job.id} not sent: withheld (#{inspect(reason)})")
    :ok
  end

  def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) when is_binary(user_id) do
    case recipient(user_id, job.args) do
      :ok ->
        open_and_deliver(job)

      {:skip, reason} ->
        Mail.forget_message(job)
        Logger.info("Mail job #{job.id} not sent: #{reason}")
        :ok

      {:error, error} ->
        # The message has to go now if this is the last attempt, as `deliver/2`
        # drops it when a delivery raises on its last one.
        if job.attempt >= job.max_attempts, do: Mail.forget_message(job)

        # The error's module only: an Ash error can quote the query.
        {:error, "could not read the recipient's account: #{error_tag(error)}"}
    end
  end

  def perform(%Oban.Job{} = job), do: open_and_deliver(job)

  # The account still holds the address the job is addressed to. Compared case
  # insensitively: the address column is citext.
  defp recipient(user_id, args) do
    with {:ok, user} <- Accounts.mail_recipient(user_id) do
      if same_address?(args["to"], to_string(user.email)),
        do: :ok,
        else: {:skip, :address_mismatch}
    end
  end

  defp same_address?([_name, address], current) when is_binary(address),
    do: String.downcase(address) == String.downcase(current)

  defp same_address?(_to, _current), do: false

  defp error_tag(%{__struct__: module}), do: inspect(module)

  defp open_and_deliver(%Oban.Job{args: args} = job) do
    case Mail.open_args(args) do
      {:ok, email} ->
        deliver(email, job)

      {:error, reason} ->
        Mail.forget_body(job)
        {:cancel, Mail.describe_open_error(reason)}
    end
  end

  # `org_id` is the site the mail was queued for (`Mail.enqueue!/2`); none
  # for account mail, which uses the operator's relay.
  defp deliver(email, %Oban.Job{args: args} = job) do
    outcome = Mail.deliver_for_worker(email, org_id: args["org_id"])
    # `:ok` or `{:cancel, _}`: either way this job is done with the message.
    Mail.forget_body(job)
    outcome
  catch
    # A raise, an exit or a throw alike: on the last attempt Oban discards
    # the job after this, so the message must go now or it never does.
    kind, reason ->
      if job.attempt >= job.max_attempts, do: Mail.forget_body(job)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # Cap each attempt so a tarpitting relay can't hold a :mail slot for gen_smtp's
  # hardcoded 20-min read timeout (see `Mail.attempt_timeout/0`).
  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()
end
