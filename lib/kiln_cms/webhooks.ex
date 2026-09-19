defmodule KilnCMS.Webhooks do
  @moduledoc """
  Outbound webhook dispatch, with a **delivery ledger**.

  When content is published, `dispatch/2` records one `WebhookDelivery` row
  and enqueues one `DeliveryWorker` Oban job per active, subscribed endpoint.
  Deliveries are signed with HMAC-SHA256 using the endpoint's secret, so
  receivers can verify authenticity.

  ## Signatures

  Every delivery carries two signatures:

    * `x-kilncms-webhook-signature: t=<unix seconds>,v1=<hex>` — the HMAC of
      `"<t>.<raw body>"`. Binding the time into the MAC is what lets a receiver
      refuse a captured request replayed later: reject anything whose `t` is
      more than `signature_tolerance/0` seconds from its own clock. The body
      also carries `delivery_id` (echoed in `x-kilncms-delivery-id`), stable
      across a delivery's retries, so a receiver can drop a duplicate inside
      the window too. `verify/4` is the reference implementation.
    * `x-kilncms-signature: <hex>` — the HMAC of the raw body alone. The
      original scheme, **deprecated**: it proves origin but not freshness. It
      is still sent so existing receivers keep working, and will be removed
      in a later release.

  Each attempt is signed when it is sent, so a retry carries a fresh `t`.

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
  @timestamped_signature_header "x-kilncms-webhook-signature"
  @delivery_id_header "x-kilncms-delivery-id"
  @event_header "x-kilncms-event"
  @signature_tolerance 300

  @doc "The deprecated body-only signature header."
  def signature_header, do: @signature_header
  @doc "The timestamped signature header (`t=…,v1=…`)."
  def timestamped_signature_header, do: @timestamped_signature_header
  def delivery_id_header, do: @delivery_id_header
  def event_header, do: @event_header

  @doc """
  How far, in seconds, a receiver should let a signature's `t` stray from its
  own clock before refusing it: five minutes, the window the docs publish and
  `verify/4` defaults to.
  """
  @spec signature_tolerance() :: pos_integer()
  def signature_tolerance, do: @signature_tolerance

  @doc """
  Lowercase hex HMAC-SHA256 of `body` keyed by `secret` — the deprecated
  `x-kilncms-signature` value.
  """
  @spec signature(String.t(), iodata()) :: String.t()
  def signature(secret, body), do: hmac_hex(secret, body)

  @doc """
  The `x-kilncms-webhook-signature` value for `body` sent at `timestamp` (unix
  seconds): `"t=<timestamp>,v1=<hex HMAC-SHA256 of \"<timestamp>.<body>\">"`.
  """
  @spec timestamped_signature(String.t(), integer(), iodata()) :: String.t()
  def timestamped_signature(secret, timestamp, body) when is_integer(timestamp) do
    "t=#{timestamp},v1=#{hmac_hex(secret, [Integer.to_string(timestamp), ".", body])}"
  end

  @doc """
  Verify an `x-kilncms-webhook-signature` header against the raw `body` — what
  a receiver does, and what the client libraries mirror.

  `:ok`, or `{:error, reason}` for a header that does not parse
  (`:malformed`), a `t` outside the tolerance (`:expired`), or no `v1` that
  matches (`:mismatch`). Several `v1` entries are accepted, any one matching,
  so a receiver keeps working while a secret is rolled.

  Options: `:tolerance` (seconds, default `signature_tolerance/0`) and `:now`
  (unix seconds, default the system clock).
  """
  @spec verify(String.t(), iodata(), String.t() | nil, keyword()) ::
          :ok | {:error, :malformed | :expired | :mismatch}
  def verify(secret, body, header, opts \\ [])

  def verify(secret, body, header, opts) when is_binary(header) do
    tolerance = Keyword.get(opts, :tolerance, @signature_tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    with {:ok, timestamp, candidates} <- parse_signature(header),
         :ok <- fresh(timestamp, now, tolerance) do
      expected = hmac_hex(secret, [Integer.to_string(timestamp), ".", body])

      if Enum.any?(candidates, &Plug.Crypto.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  def verify(_secret, _body, _header, _opts), do: {:error, :malformed}

  defp parse_signature(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2)))

    timestamps = for [k, v] <- pairs, k == "t", do: v
    candidates = for [k, v] <- pairs, k == "v1", v != "", do: String.downcase(v)

    with [raw] <- timestamps,
         {timestamp, ""} <- Integer.parse(raw),
         [_ | _] <- candidates do
      {:ok, timestamp, candidates}
    else
      _ -> {:error, :malformed}
    end
  end

  defp fresh(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance, do: :ok, else: {:error, :expired}
  end

  defp hmac_hex(secret, data),
    do: :hmac |> :crypto.mac(:sha256, secret, data) |> Base.encode16(case: :lower)

  @doc "Exhausted deliveries in a row before an endpoint is auto-disabled."
  @spec auto_disable_after() :: pos_integer()
  def auto_disable_after,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :auto_disable_after, 10)

  @doc """
  Record + enqueue a delivery for every active endpoint of `org` subscribed to
  `event`. Runs as a system job (`authorize?: false`); the endpoint scan is
  tenant-scoped (epic #336) so a publish only fans out to its own site's
  endpoints. `org` defaults to the sole org (the single-org rollout bridge).
  """
  @spec dispatch(String.t(), map(), Ash.ToTenant.t() | nil) :: :ok
  def dispatch(event, payload, org \\ KilnCMS.Accounts.default_org_id()) do
    CMS.list_webhook_endpoints!(
      authorize?: false,
      tenant: org,
      query: Ash.Query.filter(CMS.WebhookEndpoint, active == true and ^event in events)
    )
    |> Enum.each(&enqueue(&1.id, event, payload, org))

    # Editorial automation (#342) reacts to the same editorial events — this is
    # the single funnel every `<type>.published`/`.unpublished`/`.updated` flows
    # through. Scoped to the same org as the webhook fan-out (#336). Never raises
    # (a rule problem must not break the publish).
    KilnCMS.Automation.handle_event(event, payload, org)

    # ActivityPub federation (#491) is the third consumer of this funnel, for
    # the same reasons: it needs the same editorial events, scoped to the same
    # org, and it must never break a publish. Enqueue-only and non-raising,
    # like the automation call above.
    KilnCMS.Federation.handle_event(event, payload, org)

    :ok
  end

  @doc """
  Replay a delivery: a fresh ledger row (and job) for the same endpoint,
  event, and payload — history stays immutable. Admin-triggered.
  """
  @spec redeliver(struct()) :: struct()
  def redeliver(delivery),
    do: enqueue(delivery.endpoint_id, delivery.event, delivery.payload, delivery.org_id)

  @doc """
  Send a test `"ping"` event to one endpoint (delivers even when inactive, so
  a receiver can be verified before enabling). Admin-triggered.
  """
  @spec ping(struct()) :: struct()
  def ping(endpoint) do
    enqueue(
      endpoint.id,
      "ping",
      %{
        message: "KilnCMS webhook test",
        endpoint_url: endpoint.url,
        sent_at: DateTime.to_iso8601(DateTime.utc_now())
      },
      endpoint.org_id
    )
  end

  defp enqueue(endpoint_id, event, payload, org) do
    # The delivery lands in the endpoint's site, and its org rides into the job
    # args so the worker settles it under the same tenant (epic #336).
    delivery =
      CMS.create_webhook_delivery!(
        %{endpoint_id: endpoint_id, event: event, payload: payload},
        authorize?: false,
        tenant: org
      )

    %{delivery_id: delivery.id, org_id: delivery.org_id}
    |> DeliveryWorker.new()
    |> Oban.insert!()

    delivery
  end

  @doc false
  # Extra Req options (e.g. a `Req.Test` plug in the test env).
  def req_options,
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :req_options, [])
end
