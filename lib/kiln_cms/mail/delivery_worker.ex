defmodule KilnCMS.Mail.DeliveryWorker do
  @moduledoc """
  Delivers one queued email to one recipient.

  Enqueued by `KilnCMS.Mail.enqueue!/1` (one job per recipient). Rebuilds the
  Swoosh email from the serialised args and delivers it via
  `KilnCMS.Mail.deliver_for_worker/2`: a permanent (5xx) reject of the message
  cancels the job; transient failures, and the relay refusing our AUTH, TLS or
  sender, raise and retry on the greylist-aware backoff.
  """
  use Oban.Worker, queue: :mail, max_attempts: 8

  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # `org_id` is the site the mail was queued for (`Mail.enqueue!/2`); none
    # for account mail, which uses the operator's relay.
    args
    |> Mail.from_args()
    |> Mail.deliver_for_worker(org_id: args["org_id"])
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)

  # Cap each attempt so a tarpitting relay can't hold a :mail slot for gen_smtp's
  # hardcoded 20-min read timeout (see `Mail.attempt_timeout/0`).
  @impl Oban.Worker
  def timeout(_job), do: Mail.attempt_timeout()
end
