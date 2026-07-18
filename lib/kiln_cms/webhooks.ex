defmodule KilnCMS.Webhooks do
  @moduledoc """
  Outbound webhook dispatch, with a **delivery ledger**.

  When content is published, `dispatch/2` records one `WebhookDelivery` row
  and enqueues one `DeliveryWorker` Oban job per active, subscribed endpoint.
  Deliveries are signed with HMAC-SHA256 over the request body using the
  endpoint's secret, so receivers can verify authenticity.

  Reliability model (surfaced at `/editor/webhooks`):

    * every attempt updates the delivery row (attempt count, last HTTP
      status, last error); Oban retries with exponential backoff up to the
      worker's `max_attempts`;
    * a delivery that exhausts its retries is marked `:failed` and counts
      against the endpoint's `consecutive_failures` — after
      `auto_disable_after/0` in a row the endpoint is **auto-disabled**
      (any success, or an admin edit, resets the count);
    * `redeliver/1` replays any delivery as a fresh ledger row;
    * `ping/1` sends a test `"ping"` event so admins can verify a receiver
      before (or after) going live — it delivers even to inactive endpoints.
  """
  alias KilnCMS.CMS
  alias KilnCMS.Webhooks.DeliveryWorker

  require Ash.Query

  @signature_header "x-kilncms-signature"
  @event_header "x-kilncms-event"

  def signature_header, do: @signature_header
  def event_header, do: @event_header

  @doc "Lowercase hex HMAC-SHA256 of `body` keyed by `secret`."
  @spec signature(String.t(), iodata()) :: String.t()
  def signature(secret, body) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  @doc "Exhausted deliveries in a row before an endpoint is auto-disabled."
  @spec auto_disable_after() :: pos_integer()
  def auto_disable_after,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :auto_disable_after, 10)

  @doc """
  Record + enqueue a delivery for every active endpoint subscribed to `event`.
  Runs as a system job (`authorize?: false`).
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(event, payload) do
    CMS.list_webhook_endpoints!(
      authorize?: false,
      query: Ash.Query.filter(CMS.WebhookEndpoint, active == true and ^event in events)
    )
    |> Enum.each(&enqueue(&1.id, event, payload))

    # Editorial automation (#342) reacts to the same editorial events — this is
    # the single funnel every `<type>.published`/`.unpublished`/`.updated` flows
    # through. Never raises (a rule problem must not break the publish).
    KilnCMS.Automation.handle_event(event, payload)

    :ok
  end

  @doc """
  Replay a delivery: a fresh ledger row (and job) for the same endpoint,
  event, and payload — history stays immutable. Admin-triggered.
  """
  @spec redeliver(struct()) :: struct()
  def redeliver(delivery), do: enqueue(delivery.endpoint_id, delivery.event, delivery.payload)

  @doc """
  Send a test `"ping"` event to one endpoint (delivers even when inactive, so
  a receiver can be verified before enabling). Admin-triggered.
  """
  @spec ping(struct()) :: struct()
  def ping(endpoint) do
    enqueue(endpoint.id, "ping", %{
      message: "KilnCMS webhook test",
      endpoint_url: endpoint.url,
      sent_at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp enqueue(endpoint_id, event, payload) do
    delivery =
      CMS.create_webhook_delivery!(
        %{endpoint_id: endpoint_id, event: event, payload: payload},
        authorize?: false
      )

    %{delivery_id: delivery.id}
    |> DeliveryWorker.new()
    |> Oban.insert!()

    delivery
  end

  @doc false
  # Extra Req options (e.g. a `Req.Test` plug in the test env).
  def req_options,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :req_options, [])
end
