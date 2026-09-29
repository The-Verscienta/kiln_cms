defmodule KilnCMS.Webhooks.DeliveryWorker do
  @moduledoc """
  Delivers a single webhook: POSTs the signed JSON payload to one endpoint.
  Retried with backoff by Oban; non-2xx responses and transport errors fail
  the job so it retries. Every attempt is recorded on the `WebhookDelivery`
  ledger row; exhausting the retries marks it `:failed` and counts against
  the endpoint's `consecutive_failures` (auto-disable — see
  `KilnCMS.Webhooks`). A deleted endpoint settles the row and succeeds; an
  inactive one only receives `"ping"` test deliveries.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Deprecations
  alias KilnCMS.SafeFetch
  alias KilnCMS.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id, "org_id" => tenant}} = job)
      when is_binary(tenant) do
    # `org_id` scopes the ledger read/settlement to the delivery's site (epic
    # #336); every job this release enqueues carries it.
    with {:ok, delivery} <- fetch_delivery(id, tenant),
         {:ok, endpoint} <- fetch_endpoint(delivery, tenant) do
      attempt(%{delivery | endpoint: endpoint}, job)
    else
      # Ledger row pruned/deleted from under the job — nothing to deliver.
      :gone ->
        :ok

      {:error, error} ->
        Logger.error(
          "Webhook delivery #{id} could not be read, retrying: " <> Exception.message(error)
        )

        {:error, error}
    end
  end

  # Any other shape was enqueued by a release before 0.12: a ledger job with no
  # `org_id`, or a pre-ledger `endpoint_id`/`event`/`payload` job. 0.12 still
  # ran both with a deprecation warning; 1.0 removed them (#1543). Cancelled,
  # not raised: a crash would retry a job that can never succeed, and running it
  # against a guessed org is exactly the fallback that was removed.
  def perform(%Oban.Job{args: args}), do: Deprecations.cancel_legacy_job(__MODULE__, args)

  # Both reads run as `Webhooks.system/0` (#1659) with `authorize_with: :error`.
  # Under a filter policy a refused read comes back as "not found", and each
  # "not found" here is a decision: a missing ledger row means "pruned, nothing
  # to deliver" (the job succeeds and the webhook is never sent), and a missing
  # endpoint means "deleted" (the row is settled as failed and the job
  # succeeds). A lost grant must read as neither. With `:error` it is a
  # Forbidden, which `perform/1` logs and hands to Oban to retry.
  #
  # The endpoint is read on its own rather than `load:`-ed with the delivery:
  # a relationship load authorizes with the relationship's own
  # `authorize_read_with` (`:filter` by default), not with the parent read's,
  # so a refused endpoint would have loaded as `nil`, which is "deleted".
  defp fetch_delivery(id, tenant) do
    case CMS.get_webhook_delivery(id,
           actor: Webhooks.system(),
           authorize_with: :error,
           tenant: tenant
         ) do
      {:ok, delivery} -> {:ok, delivery}
      {:error, error} -> if not_found?(error), do: :gone, else: {:error, error}
    end
  end

  defp fetch_endpoint(delivery, tenant) do
    case CMS.get_webhook_endpoint(delivery.endpoint_id,
           actor: Webhooks.system(),
           authorize_with: :error,
           tenant: tenant
         ) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, error} -> if not_found?(error), do: {:ok, nil}, else: {:error, error}
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.all?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(_error), do: false

  defp attempt(%{endpoint: endpoint} = delivery, job) do
    cond do
      is_nil(endpoint) or match?(%Ash.NotLoaded{}, endpoint) ->
        settle(delivery, job, {:error, "endpoint deleted"}, true)
        :ok

      not endpoint.active and delivery.event != "ping" ->
        settle(delivery, job, {:error, "endpoint inactive"}, true)
        :ok

      true ->
        outcome = deliver(endpoint, delivery.id, delivery.event, delivery.payload)
        settle(delivery, job, outcome, job.attempt >= job.max_attempts)

        case outcome do
          {:ok, _status} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Record this attempt on the ledger row — and, when the outcome is final,
  # on the endpoint's health counters (success resets, exhaustion bumps and
  # may auto-disable).
  #
  # Written as `Webhooks.system/0` (#1659). A bookkeeping write that fails —
  # the grant lost, or the database — is LOGGED and does not change the job's
  # outcome, which the POST alone decides. Raising here after a 2xx would fail
  # the job and have Oban send the webhook again, a duplicate the receiver can
  # only drop by `delivery_id`; swallowing it without a word would leave the
  # row `:pending` with nobody told why.
  defp settle(delivery, job, {:ok, status}, _final?) do
    # The fetched delivery/endpoint carry their org; settle under it (epic #336).
    delivery
    |> CMS.record_webhook_delivery_attempt(
      %{
        status: :succeeded,
        attempts: job.attempt,
        last_status: status,
        last_error: nil,
        delivered_at: DateTime.utc_now()
      },
      actor: Webhooks.system(),
      tenant: delivery.org_id
    )
    |> log_unrecorded(delivery, "attempt")

    if delivery.endpoint do
      delivery.endpoint
      |> CMS.record_webhook_success(%{}, actor: Webhooks.system(), tenant: delivery.org_id)
      |> log_unrecorded(delivery, "endpoint success")
    end
  end

  defp settle(delivery, job, {:error, reason}, final?) do
    delivery
    |> CMS.record_webhook_delivery_attempt(
      %{
        status: if(final?, do: :failed, else: :pending),
        attempts: job.attempt,
        last_status: parse_status(reason),
        last_error: reason
      },
      actor: Webhooks.system(),
      tenant: delivery.org_id
    )
    |> log_unrecorded(delivery, "attempt")

    # Bump health only for a live endpoint that truly exhausted its retries —
    # a failed ping against an already-disabled endpoint proves nothing new.
    if final? and is_struct(delivery.endpoint, KilnCMS.CMS.WebhookEndpoint) and
         delivery.endpoint.active do
      delivery.endpoint
      |> CMS.record_webhook_failure(%{}, actor: Webhooks.system(), tenant: delivery.org_id)
      |> log_unrecorded(delivery, "endpoint failure")
    end
  end

  defp log_unrecorded({:ok, _record}, _delivery, _what), do: :ok

  defp log_unrecorded({:error, error}, delivery, what) do
    Logger.error(
      "Webhook delivery #{delivery.id}: #{what} not recorded on the ledger: " <>
        Exception.message(error)
    )
  end

  # "endpoint returned HTTP 503" → 503, for the ledger's status column.
  defp parse_status("endpoint returned HTTP " <> code), do: String.to_integer(code)
  defp parse_status(_reason), do: nil

  # The address pinning, the TLS options that keep SNI and hostname
  # verification pointed at the real name, the restored `Host` header and the
  # refusal to follow a redirect all live in `KilnCMS.SafeFetch` — extracted
  # from this function, and since #753 called from it rather than copied beside
  # it. There was one correct implementation and two copies of it; the next
  # TLS-option edit would have touched one.
  #
  # A secret that does not open (the `SECRET_KEY_BASE` it was encrypted under
  # has been rotated away) refuses the delivery rather than sending it unsigned
  # or signed with something the receiver never saw: either would be rejected
  # at a receiver that verifies, and accepted at one that does not.
  defp deliver(endpoint, delivery_id, event, payload) do
    case WebhookEndpoint.secret(endpoint) do
      nil -> {:error, "delivery failed: signing secret unreadable"}
      secret -> post(endpoint, secret, delivery_id, event, payload)
    end
  end

  defp post(endpoint, secret, delivery_id, event, payload) do
    # `delivery_id` rides inside the body, so the signature covers it; the
    # header copy is for routing and logging without a parse. Stable across a
    # delivery's retries — it is the ledger row's id.
    body = Jason.encode!(%{event: event, data: payload, delivery_id: delivery_id})

    # Headers are built here, at send time, from nothing the job stored: a job
    # enqueued before an upgrade goes out with the headers of the release that
    # runs it. That is how #1616 dropped the body-only `x-kilncms-signature`
    # without a job migration.
    timestamp = System.system_time(:second)

    headers =
      [
        {"content-type", "application/json"},
        {Webhooks.timestamped_signature_header(),
         Webhooks.timestamped_signature(secret, timestamp, body)},
        {Webhooks.event_header(), event},
        {Webhooks.delivery_id_header(), delivery_id}
      ]

    endpoint.url
    |> SafeFetch.post(body,
      headers: headers,
      # Bound how long a slow or hanging endpoint can hold this Oban worker;
      # queue concurrency is limited. `req_options` is applied last, so the
      # test env can still override it.
      receive_timeout: 15_000,
      # A webhook receiver's response body is never read — only its status
      # decides the ledger. `truncate_body: true` keeps the default byte cap
      # protecting this worker's memory while making a chatty endpoint a
      # delivered 200 rather than a failure, which is what it was before the
      # cap existed.
      truncate_body: true,
      req_options: Webhooks.req_options()
    )
    |> classify()
  end

  # The ledger's `last_error` is read by humans and its vocabulary is documented
  # on `KilnCMS.CMS.WebhookDelivery` — `"endpoint returned HTTP 500"`,
  # `"delivery failed: timeout"`, `"blocked webhook URL: …"`. `SafeFetch` writes
  # for its own callers and prefixes differently, so each of its shapes is
  # translated rather than wrapped: wrapping produced
  # `"delivery failed: request failed: %Req.TransportError{…}"`, which is the
  # documented vocabulary with somebody else's inside it.
  #
  # Matching on another module's message text is a deliberate coupling to a
  # display string. Getting it wrong costs a less specific message, never a
  # wrong delivery outcome — every clause below settles the same way. The
  # translations are pinned by tests so a reworded `SafeFetch` goes red here
  # instead of quietly double-prefixing again.
  defp classify({:ok, %{status: status}}) when status in 200..299, do: {:ok, status}
  defp classify({:ok, %{status: status}}), do: {:error, "endpoint returned HTTP #{status}"}

  defp classify({:error, "blocked URL: " <> reason}),
    do: {:error, "blocked webhook URL: #{reason}"}

  defp classify({:error, "request failed: " <> reason}),
    do: {:error, "delivery failed: #{reason}"}

  defp classify({:error, reason}), do: {:error, "delivery failed: #{reason}"}
end
