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

  alias KilnCMS.CMS
  alias KilnCMS.SafeFetch
  alias KilnCMS.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id} = args} = job) do
    # `org_id` scopes the ledger read/settlement to the delivery's site (epic
    # #336). Strict-tenancy prep (#419): a legacy job with no org resolves the
    # default org explicitly (matching the firing workers) instead of a
    # nil-tenant global read.
    tenant = args["org_id"] || KilnCMS.Accounts.default_org_id()

    case CMS.get_webhook_delivery(id, authorize?: false, tenant: tenant, load: [:endpoint]) do
      {:ok, delivery} -> attempt(delivery, job)
      # Ledger row pruned/deleted from under the job — nothing to deliver.
      _ -> :ok
    end
  end

  # Legacy args shape: jobs enqueued before the ledger existed may still sit
  # in the queue across a deploy. Deliver without recording; pre-ledger jobs
  # predate multi-tenancy, so the endpoint lives in the default org (#419).
  def perform(%Oban.Job{args: %{"endpoint_id" => id, "event" => event, "payload" => payload}}) do
    case CMS.get_webhook_endpoint(id,
           authorize?: false,
           tenant: KilnCMS.Accounts.default_org_id()
         ) do
      {:ok, %{active: true} = endpoint} ->
        case deliver(endpoint, event, payload) do
          {:ok, _status} -> :ok
          error -> error
        end

      _ ->
        :ok
    end
  end

  defp attempt(%{endpoint: endpoint} = delivery, job) do
    cond do
      is_nil(endpoint) or match?(%Ash.NotLoaded{}, endpoint) ->
        settle(delivery, job, {:error, "endpoint deleted"}, true)
        :ok

      not endpoint.active and delivery.event != "ping" ->
        settle(delivery, job, {:error, "endpoint inactive"}, true)
        :ok

      true ->
        outcome = deliver(endpoint, delivery.event, delivery.payload)
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
  defp settle(delivery, job, {:ok, status}, _final?) do
    # The fetched delivery/endpoint carry their org; settle under it (epic #336).
    CMS.record_webhook_delivery_attempt!(
      delivery,
      %{
        status: :succeeded,
        attempts: job.attempt,
        last_status: status,
        last_error: nil,
        delivered_at: DateTime.utc_now()
      },
      authorize?: false,
      tenant: delivery.org_id
    )

    if delivery.endpoint do
      CMS.record_webhook_success!(delivery.endpoint, %{},
        authorize?: false,
        tenant: delivery.org_id
      )
    end
  end

  defp settle(delivery, job, {:error, reason}, final?) do
    CMS.record_webhook_delivery_attempt!(
      delivery,
      %{
        status: if(final?, do: :failed, else: :pending),
        attempts: job.attempt,
        last_status: parse_status(reason),
        last_error: reason
      },
      authorize?: false,
      tenant: delivery.org_id
    )

    # Bump health only for a live endpoint that truly exhausted its retries —
    # a failed ping against an already-disabled endpoint proves nothing new.
    if final? and is_struct(delivery.endpoint, KilnCMS.CMS.WebhookEndpoint) and
         delivery.endpoint.active do
      CMS.record_webhook_failure!(delivery.endpoint, %{},
        authorize?: false,
        tenant: delivery.org_id
      )
    end
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
  defp deliver(endpoint, event, payload) do
    body = Jason.encode!(%{event: event, data: payload})

    headers = [
      {"content-type", "application/json"},
      {Webhooks.signature_header(), Webhooks.signature(endpoint.secret, body)},
      {Webhooks.event_header(), event}
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
  # on `KilnCMS.CMS.WebhookDelivery`, so the two shapes it already had are kept
  # verbatim. Matching `SafeFetch`'s own prefix is a deliberate coupling to a
  # display string: getting it wrong costs a less specific message, never a
  # wrong delivery outcome, because the last clause is correct either way.
  defp classify({:ok, %{status: status}}) when status in 200..299, do: {:ok, status}
  defp classify({:ok, %{status: status}}), do: {:error, "endpoint returned HTTP #{status}"}

  defp classify({:error, "blocked URL: " <> reason}),
    do: {:error, "blocked webhook URL: #{reason}"}

  defp classify({:error, reason}), do: {:error, "delivery failed: #{reason}"}
end
