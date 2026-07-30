defmodule KilnCMS.Billing.Providers.Stripe do
  @moduledoc """
  `KilnCMS.Billing.Provider` over the Stripe REST API, with Req.

  Hand-rolled rather than a client dependency, deliberately: the surface is five
  endpoints against a famously stable API, and every other outbound integration
  here (`KilnCMS.Webhooks`, `KilnCMS.Unsplash`, `Kiln.Updates`,
  `KilnCMS.Search.Meilisearch`) is Req plus a `req_options` test seam. A
  third-party client with its own transport config could not be stubbed with
  `Req.Test`, which would mean a second, inconsistent mocking style for the most
  security-sensitive integration in the tree — and it would add a permanent
  advisory surface to the `mix deps.audit` gate for roughly 80 lines of saved
  code.

  ## Encoding

  Stripe takes `application/x-www-form-urlencoded` with bracket notation
  (`line_items[0][price]=…`, `subscription_data[metadata][org_id]=…`), so nested
  params are flattened by `encode_params/1` before Req sees them. That flattener
  is the one piece of real work a dependency would have saved, and it has its own
  unit test because the nesting rules are the sharp edge.

  ## Metadata contract

  Checkout-session metadata does **not** propagate to the subscription object
  Stripe creates, and the subscription is what carries every later event —
  including the cancellation that drives revocation. So callers must stamp
  **both** `metadata` and `subscription_data[metadata]` when opening a checkout
  session. The webhook receiver relies on this to resolve the owning organization
  from the event itself rather than trusting the request host.

  The API version is pinned so a Stripe-side default bump cannot silently
  reshape the subscription object the entitlement state machine reads.
  """
  @behaviour KilnCMS.Billing.Provider

  @base_url "https://api.stripe.com"
  @api_version "2025-04-30.basil"
  @receive_timeout 15_000

  @impl true
  def create_checkout_session(params, config) do
    with {:ok, body} <- post("/v1/checkout/sessions", params, config) do
      {:ok, %{id: body["id"], url: body["url"]}}
    end
  end

  @impl true
  def create_portal_session(params, config) do
    with {:ok, body} <- post("/v1/billing_portal/sessions", params, config) do
      {:ok, %{id: body["id"], url: body["url"]}}
    end
  end

  @impl true
  def retrieve_subscription(id, config), do: get("/v1/subscriptions/" <> id, config)

  @impl true
  def retrieve_checkout_session(id, config) do
    # `line_items` is not included by default and the tier is resolved from the
    # price id, so ask for it explicitly.
    get("/v1/checkout/sessions/" <> id, config, expand: ["line_items", "subscription"])
  end

  @impl true
  def verify_webhook(raw_body, signature_header, secret, opts \\ []) do
    KilnCMS.Billing.Providers.Stripe.Signature.verify(raw_body, signature_header, secret, opts)
  end

  @doc """
  Confirm the credentials work and report which account they belong to.

  Used by the console's "Test connection" so a mistyped key fails at save time
  rather than at a member's first checkout.
  """
  @spec retrieve_account(KilnCMS.Billing.Provider.config()) :: {:ok, map()} | {:error, term()}
  def retrieve_account(config), do: get("/v1/account", config)

  ## HTTP

  defp get(path, config, query \\ []) do
    request(
      [method: :get, url: url(path)] ++ query_option(query),
      config
    )
  end

  defp post(path, params, config) do
    request(
      [
        method: :post,
        url: url(path),
        form: encode_params(params),
        # A retried create must not mint a second session/subscription. Callers
        # supply a stable key derived from their intent.
        headers: idempotency_header(params)
      ],
      config
    )
  end

  defp request(options, config) do
    options =
      options
      |> Keyword.update(:headers, auth_headers(config), &(&1 ++ auth_headers(config)))
      |> Keyword.put(:receive_timeout, @receive_timeout)
      # No automatic retry: POSTs are money-moving and carry an idempotency key,
      # so retry policy belongs to the caller (Oban), not to Req.
      |> Keyword.put(:retry, false)
      # Last, so a `Req.Test` plug in test/dev wins over anything above.
      |> Keyword.merge(KilnCMS.Billing.req_options())

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp url(path), do: @base_url <> path

  defp query_option([]), do: []
  defp query_option(query), do: [params: encode_params(Map.new(query))]

  defp auth_headers(%{secret_key: secret_key}) do
    [
      {"authorization", "Bearer " <> secret_key},
      {"stripe-version", @api_version}
    ]
  end

  defp idempotency_header(%{idempotency_key: key}) when is_binary(key) and key != "",
    do: [{"idempotency-key", key}]

  defp idempotency_header(_params), do: []

  @doc """
  Flatten nested params into Stripe's bracket notation.

  Maps nest by key (`metadata[org_id]`), lists nest by index
  (`line_items[0][price]`). `nil` values are dropped rather than sent as empty
  strings, which Stripe would treat as an explicit unset. `:idempotency_key` is
  removed — it travels as a header, not a form field.

      iex> encode_params(%{mode: "subscription", metadata: %{org_id: "a"}})
      [{"metadata[org_id]", "a"}, {"mode", "subscription"}]
  """
  @spec encode_params(map()) :: [{String.t(), String.t()}]
  def encode_params(params) when is_map(params) do
    params
    |> Map.drop([:idempotency_key, "idempotency_key"])
    |> flatten(nil)
    |> Enum.sort()
  end

  defp flatten(value, prefix) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {key, inner} -> flatten(inner, nest(prefix, key)) end)
  end

  defp flatten(value, prefix) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {inner, index} -> flatten(inner, nest(prefix, index)) end)
  end

  defp flatten(nil, _prefix), do: []
  defp flatten(value, nil), do: [{"", to_string(value)}]
  defp flatten(value, prefix) when is_boolean(value), do: [{prefix, to_string(value)}]
  defp flatten(%DateTime{} = value, prefix), do: [{prefix, to_string(DateTime.to_unix(value))}]
  defp flatten(value, prefix), do: [{prefix, to_string(value)}]

  defp nest(nil, key), do: to_string(key)
  defp nest(prefix, key), do: "#{prefix}[#{key}]"
end
