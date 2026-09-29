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
    # As the billing system actor (#1659), which `WebhookEvent` admits for the
    # plain `:read` by name. `authorize_with: :error` because a refused read
    # would otherwise come back `nil`, and `nil` means "the event is gone":
    # the job would cancel and a payment event would never be applied. A
    # refusal is an error, and Oban retries.
    case Billing.get_webhook_event(id,
           actor: Billing.system(),
           authorize_with: :error,
           not_found_error?: false
         ) do
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
    case Billing.claim_webhook_event(event, actor: Billing.system()) do
      {:ok, claimed} ->
        process(claimed)

      # A refused claim is not "someone else has it": cancelling would strand
      # the event unapplied. Nothing was written, so a retry is safe — the
      # claim stays the one gate that stops an event being processed twice.
      {:error, %Ash.Error.Forbidden{} = reason} ->
        Logger.error(
          "billing webhook #{event.provider_event_id}: claim refused: #{inspect(reason)}"
        )

        {:error, reason}

      # Someone else already claimed it — an Oban re-execution, or a duplicate that
      # slipped past the insert guard. Either way there is nothing to do.
      {:error, _reason} ->
        {:cancel, :already_claimed}
    end
  end

  defp process(event) do
    case Subscriptions.apply(event.payload) do
      {:ok, membership} ->
        settle(
          event,
          :mark_processed,
          Billing.mark_webhook_event_processed(
            event,
            %{org_id: membership.org_id, membership_id: membership.id},
            actor: Billing.system()
          )
        )

        :ok

      {:ignored, reason} ->
        settle(
          event,
          :mark_ignored,
          Billing.mark_webhook_event_ignored(event, %{error: to_string(reason)},
            actor: Billing.system()
          )
        )

        :ok

      {:error, reason} ->
        # Transient. Record the reason for the console, then let Oban retry.
        settle(
          event,
          :mark_failed,
          Billing.mark_webhook_event_failed(event, %{error: inspect(reason)},
            actor: Billing.system()
          )
        )

        Logger.error("billing webhook #{event.provider_event_id} failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # The settle stamps run as the billing system actor, which `WebhookEvent`
  # admits for these three updates by name (#1659). Their result used to be
  # dropped; a stamp that does not land leaves the event `:processing`, which
  # the console shows as in flight forever, so it is logged. It does not fail
  # the job: the membership transition has already committed (or, for
  # `:mark_failed`, the job is failing anyway), and the claim — not this
  # stamp — is what keeps a retry from applying the event twice.
  defp settle(_event, _stamp, {:ok, _event_row}), do: :ok

  defp settle(event, stamp, {:error, reason}) do
    Logger.error(
      "billing webhook #{event.provider_event_id}: #{stamp} was not saved: #{inspect(reason)}"
    )
  end
end
