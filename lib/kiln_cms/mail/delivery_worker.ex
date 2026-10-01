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
  """
  use Oban.Worker, queue: :mail, max_attempts: 8

  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
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
  rescue
    error ->
      # The last attempt: Oban discards the job after this raise.
      if job.attempt >= job.max_attempts, do: Mail.forget_body(job)
      reraise error, __STACKTRACE__
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # Cap each attempt so a tarpitting relay can't hold a :mail slot for gen_smtp's
  # hardcoded 20-min read timeout (see `Mail.attempt_timeout/0`).
  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()
end
