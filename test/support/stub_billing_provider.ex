defmodule KilnCMS.StubBillingProvider do
  @moduledoc """
  A `KilnCMS.Billing.Provider` test double.

  ## Why not `Req.Test`

  `Req.Test` stubs are **process-scoped**. Webhook processing happens in an Oban
  worker, which may run in a different process from the test — so a `Req.Test`
  stub is not visible there and Req falls through to the *real* network. That is
  not hypothetical: it made a test issue a live request to the payment provider
  and fail on a genuine 401.

  Selecting the provider through app env instead is global to the node, so every
  process — worker included — sees the double, and no test can reach the network.
  It is also the seam the browser suite needs, since `config/e2e.exs` notes the
  e2e run cannot use a `Req.Test` stub.

  Use it via:

      setup do
        Application.put_env(:kiln_cms, KilnCMS.Billing,
          provider: KilnCMS.StubBillingProvider
        )

        on_exit(fn -> Application.delete_env(:kiln_cms, KilnCMS.Billing) end)
      end

  Responses are configurable per-test by putting values under
  `:stub_billing_provider` in app env; the defaults describe a healthy active
  subscription.
  """
  @behaviour KilnCMS.Billing.Provider

  @impl true
  def create_checkout_session(params, _config) do
    spy(:checkout_session, params)

    case setting(:checkout_session) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        {:ok,
         %{
           id: "cs_stub_#{:erlang.phash2(params)}",
           url: "https://checkout.example.test/c/pay/cs_stub"
         }}

      session ->
        {:ok, session}
    end
  end

  @impl true
  def create_portal_session(_params, _config) do
    case setting(:portal_session) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, %{id: "bps_stub", url: "https://billing.example.test/p/session/stub"}}
      session -> {:ok, session}
    end
  end

  @impl true
  def retrieve_subscription(id, _config) do
    case setting(:subscription) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, subscription(id, "active")}
      subscription -> {:ok, subscription}
    end
  end

  @impl true
  def retrieve_checkout_session(id, _config) do
    case setting(:checkout_session_retrieve) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, %{"id" => id, "status" => "complete", "mode" => "subscription"}}
      session -> {:ok, session}
    end
  end

  @impl true
  def retrieve_account(_config) do
    case setting(:account) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, %{"id" => "acct_stub", "charges_enabled" => true}}
      account -> {:ok, account}
    end
  end

  # Signature verification is local and has no network dependency, so the real
  # implementation is used — a stub here would hide the property most worth
  # testing.
  @impl true
  def verify_webhook(raw_body, signature_header, secret, opts) do
    KilnCMS.Billing.Providers.Stripe.Signature.verify(raw_body, signature_header, secret, opts)
  end

  @doc "A subscription object in the provider's shape."
  def subscription(id, status, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "object" => "subscription",
        "status" => status,
        "customer" => "cus_stub",
        "cancel_at_period_end" => false,
        "current_period_end" => DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix()
      },
      overrides
    )
  end

  @doc "Override one stubbed response for the current test."
  def put(key, value) do
    settings = Application.get_env(:kiln_cms, :stub_billing_provider, %{})
    Application.put_env(:kiln_cms, :stub_billing_provider, Map.put(settings, key, value))
  end

  @doc """
  Forward the params of each `key` call to `pid`, so a test can assert on what
  was sent to the provider.

      StubBillingProvider.spy_on(:checkout_session, self())
      ...
      assert_received {:stub_billing, :checkout_session, params}
  """
  def spy_on(key, pid), do: put({:spy, key}, pid)

  defp spy(key, params) do
    case setting({:spy, key}) do
      pid when is_pid(pid) -> send(pid, {:stub_billing, key, params})
      _other -> :ok
    end
  end

  defp setting(key),
    do: Application.get_env(:kiln_cms, :stub_billing_provider, %{})[key]
end
