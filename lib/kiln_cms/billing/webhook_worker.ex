defmodule KilnCMS.Billing.WebhookWorker do
  @moduledoc """
  Processes one recorded provider webhook event.

  The receiver has already verified the signature and durably recorded the event;
  this worker claims it and applies the membership transition.

  ## Three independent idempotency layers

  1. The unique identity on `{provider, provider_event_id}` means a concurrent
     duplicate delivery never gets a job.
  2. `:claim` is an atomic filtered update, so an Oban **re-execution** (a crash
     between running and acking) finds zero rows and cancels.
  3. `KilnCMS.Billing.Entitlements.recompute/1` is a pure function of current
     state, so even if 1 and 2 were both defeated, re-application cannot
     double-grant.

  `{:cancel, reason}` is used for permanently unactionable conditions — already
  claimed, unresolvable, an unhandled type — so Oban stops retrying. Transient
  failures (a provider 5xx, `:econnrefused`) return `{:error, _}` so Oban retries
  with backoff; the event stays `:processing` until a later attempt settles it.
  """
  use Oban.Worker, queue: :billing, max_attempts: 8

  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Billing.Subscriptions

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => id}}) do
    case Billing.get_webhook_event(id, authorize?: false, not_found_error?: false) do
      {:ok, nil} ->
        {:cancel, :event_gone}

      {:ok, event} ->
        claim_and_process(event)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: KilnCMS.Mail.backoff_seconds(attempt)

  defp claim_and_process(event) do
    case Billing.claim_webhook_event(event, authorize?: false) do
      {:ok, claimed} ->
        process(claimed)

      # Someone else already claimed it — an Oban re-execution, or a duplicate that
      # slipped past the insert guard. Either way there is nothing to do.
      {:error, _reason} ->
        {:cancel, :already_claimed}
    end
  end

  defp process(event) do
    case Subscriptions.apply(event.payload) do
      {:ok, membership} ->
        Billing.mark_webhook_event_processed(
          event,
          %{org_id: membership.org_id, membership_id: membership.id},
          authorize?: false
        )

        :ok

      {:ignored, reason} ->
        Billing.mark_webhook_event_ignored(event, %{error: to_string(reason)}, authorize?: false)

        :ok

      {:error, reason} ->
        # Transient. Record the reason for the console, then let Oban retry.
        Billing.mark_webhook_event_failed(event, %{error: inspect(reason)}, authorize?: false)

        Logger.error("billing webhook #{event.provider_event_id} failed: #{inspect(reason)}")

        {:error, reason}
    end
  end
end
