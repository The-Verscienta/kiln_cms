defmodule KilnCMS.Mail.DeliveryWorker do
  @moduledoc """
  Delivers one queued email to one recipient.

  Enqueued by `KilnCMS.Mail.enqueue!/1` (one job per recipient). Rebuilds the
  Swoosh email from the serialised args and delivers it via
  `KilnCMS.Mail.deliver_for_worker/2`: permanent (5xx) failures cancel the
  job, transient failures raise and retry on the greylist-aware backoff.
  """
  use Oban.Worker, queue: :mail, max_attempts: 8

  alias KilnCMS.Mail

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args
    |> Mail.from_args()
    |> Mail.deliver_for_worker()
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: Mail.backoff_seconds(attempt)
end
