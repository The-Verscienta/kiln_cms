defmodule KilnCMS.Billing.WebhookWorker do
  @moduledoc """
  Processes one recorded provider webhook event.

  The receiver has already verified the signature and durably recorded the event;
  this worker claims it and applies the membership transition.

  ## Idempotency layers

  1. The unique identity on `{provider, provider_event_id}` means a duplicate
     delivery never inserts a second row.
  2. The job is `unique` on the event id while it is `:available`, `:scheduled`
     or `:retryable`, so a redelivery that re-enqueues (the row is still
     `:received`/`:failed`, #2748) adds no second job to the queue. `:executing`
     is deliberately **not** a unique state: a node killed mid-run leaves its job
     `:executing` until `Oban.Lifeline` rescues it (180 minutes by default), and
     the provider's redelivery must be able to enqueue a fresh job meanwhile. A
     second job running next to a live one is harmless because of 3.
  3. `:claim` is an atomic filtered update, so an Oban **re-execution** (a crash
     between running and acking) or a concurrent second job finds zero rows and
     cancels. A `:processing` claim older than
     `KilnCMS.Billing.WebhookEvent.reclaim_after_ms/0` is taken over instead: its
     worker is presumed dead.
  4. `KilnCMS.Billing.Entitlements.recompute/1` is a pure function of current
     state, so even if the rest were defeated, re-application cannot
     double-grant.

  `timeout/1` bounds one run strictly below the reclaim threshold, so a live run
  can never be mistaken for a dead one. An exception, exit or throw inside
  `Subscriptions.apply/1` is caught and settled as `:failed`, and Oban retries.

  Known windows that still need a periodic sweeper (follow-up): a job that
  exhausts `max_attempts` leaves the event `:failed` until the provider happens to
  redeliver; a `:mark_processed` stamp that does not save leaves the event
  `:processing`; and `:received` rows recorded before enqueue became atomic have
  no job.

  `{:cancel, reason}` is used for permanently unactionable conditions — already
  claimed, unresolvable, an unhandled type — so Oban stops retrying. Transient
  failures (a provider 5xx, `:econnrefused`) return `{:error, _}` so Oban retries
  with backoff; the event stays `:processing` until a later attempt settles it.
  """
  use Oban.Worker,
    queue: :billing,
    max_attempts: 8,
    unique: [
      keys: [:webhook_event_id],
      states: [:available, :scheduled, :retryable],
      period: :infinity
    ]

  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Billing.Subscriptions

  # Generous for one event (a provider call or two at 15 s each, plus a
  # transaction) yet far below `WebhookEvent.reclaim_after_ms/0` (10 min).
  @run_timeout :timer.minutes(3)

  @doc """
  Enqueues the job for a recorded event. `{:ok, job}` also covers a unique
  conflict (the pending job is returned), which is success: the event is queued.

  Called from `WebhookEvent`'s `:receive` inside its transaction, and by the
  receiver when a redelivery finds an unsettled row.
  """
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{id: id}) do
    # `:billing_webhook_insert` is a test seam for forcing an enqueue failure;
    # unset in every real environment.
    insert = Application.get_env(:kiln_cms, :billing_webhook_insert, &Oban.insert/1)

    %{"webhook_event_id" => id}
    |> new()
    |> insert.()
  end

  @impl Oban.Worker
  def timeout(_job), do: @run_timeout

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

      # The claim's `UPDATE` matched no row: a live worker holds it, or it is
      # settled. An Oban re-execution or a concurrent duplicate job; nothing to do.
      {:error, %Ash.Error.Invalid{errors: errors} = reason} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
          {:cancel, :already_claimed}
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process(event) do
    case apply_event(event) do
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

  # A crash inside the transition must not leave the row `:processing`: caught
  # here it settles as `:failed` and Oban retries (the retry's claim accepts
  # `:failed`). Rescue is justified: this is the boundary around third-party
  # provider code and a multi-row transaction.
  defp apply_event(event) do
    Subscriptions.apply(event.payload)
  rescue
    exception ->
      Logger.error(
        "billing webhook #{event.provider_event_id} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason when kind in [:exit, :throw] ->
      {:error, {kind, inspect(reason)}}
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
