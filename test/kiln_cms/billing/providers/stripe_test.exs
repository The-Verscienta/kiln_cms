defmodule KilnCMS.Billing.Providers.StripeTest do
  @moduledoc """
  The Stripe adapter: form encoding, headers, and error mapping.

  All HTTP goes through the `Req.Test` stub wired up in `config/test.exs`, so no
  test ever reaches api.stripe.com.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Billing.Providers.Stripe

  @config %{secret_key: "sk_test_abc123"}

  defp capture_request(response_body) do
    parent = self()

    Req.Test.stub(KilnCMS.Billing, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, body, conn.req_headers})
      Req.Test.json(conn, response_body)
    end)
  end

  defp received_request do
    receive do
      {:request, method, path, body, headers} ->
        %{method: method, path: path, body: body, headers: headers}
    after
      0 -> flunk("no HTTP request was made")
    end
  end

  describe "encode_params/1" do
    test "flattens a nested map into bracket notation" do
      assert Stripe.encode_params(%{mode: "subscription", metadata: %{org_id: "abc"}}) ==
               [{"metadata[org_id]", "abc"}, {"mode", "subscription"}]
    end

    test "flattens a list by index" do
      params = %{line_items: [%{price: "price_1", quantity: 1}]}

      assert Stripe.encode_params(params) == [
               {"line_items[0][price]", "price_1"},
               {"line_items[0][quantity]", "1"}
             ]
    end

    test "flattens deeply nested maps" do
      params = %{subscription_data: %{metadata: %{tier_id: "t1"}}}

      assert Stripe.encode_params(params) == [
               {"subscription_data[metadata][tier_id]", "t1"}
             ]
    end

    test "drops nil values rather than sending empty strings" do
      # Stripe treats an empty string as an explicit unset, which is a different
      # operation from "not provided".
      assert Stripe.encode_params(%{a: nil, b: "keep"}) == [{"b", "keep"}]
    end

    test "encodes booleans" do
      assert Stripe.encode_params(%{flag: false}) == [{"flag", "false"}]
    end

    test "encodes a DateTime as a unix timestamp" do
      at = DateTime.from_unix!(1_700_000_000)

      assert Stripe.encode_params(%{trial_end: at}) == [{"trial_end", "1700000000"}]
    end

    test "removes the idempotency key — it travels as a header" do
      assert Stripe.encode_params(%{idempotency_key: "abc", mode: "subscription"}) ==
               [{"mode", "subscription"}]
    end
  end

  describe "create_checkout_session/2" do
    test "posts form-encoded params and returns the hosted URL" do
      capture_request(%{"id" => "cs_123", "url" => "https://checkout.stripe.com/c/pay/cs_123"})

      assert {:ok, session} =
               Stripe.create_checkout_session(
                 %{
                   mode: "subscription",
                   line_items: [%{price: "price_1", quantity: 1}],
                   metadata: %{org_id: "org-1", membership_id: "m-1"},
                   subscription_data: %{metadata: %{org_id: "org-1", membership_id: "m-1"}},
                   idempotency_key: "checkout:m-1"
                 },
                 @config
               )

      assert session.id == "cs_123"
      assert session.url == "https://checkout.stripe.com/c/pay/cs_123"

      request = received_request()
      assert request.method == "POST"
      assert request.path == "/v1/checkout/sessions"

      params = URI.decode_query(request.body)
      assert params["mode"] == "subscription"
      assert params["line_items[0][price]"] == "price_1"
      # Both metadata maps must be present: session metadata does not propagate
      # to the subscription, and the subscription carries every later event.
      assert params["metadata[org_id]"] == "org-1"
      assert params["subscription_data[metadata][org_id]"] == "org-1"
      assert params["subscription_data[metadata][membership_id]"] == "m-1"
    end

    test "sends auth, pinned API version and idempotency headers" do
      capture_request(%{"id" => "cs_1", "url" => "https://example.test"})

      {:ok, _session} =
        Stripe.create_checkout_session(%{idempotency_key: "checkout:m-1"}, @config)

      headers = Map.new(received_request().headers)

      assert headers["authorization"] == "Bearer sk_test_abc123"
      # Pinned, so a provider-side default bump can't reshape the subscription
      # object the entitlement state machine reads.
      assert headers["stripe-version"]
      assert headers["idempotency-key"] == "checkout:m-1"
    end

    test "omits the idempotency header when no key is given" do
      capture_request(%{"id" => "cs_1", "url" => "https://example.test"})

      {:ok, _session} = Stripe.create_checkout_session(%{mode: "subscription"}, @config)

      refute Map.new(received_request().headers)["idempotency-key"]
    end
  end

  describe "create_portal_session/2" do
    test "returns the portal URL" do
      capture_request(%{"id" => "bps_1", "url" => "https://billing.stripe.com/p/session/x"})

      assert {:ok, %{url: "https://billing.stripe.com/p/session/x"}} =
               Stripe.create_portal_session(%{customer: "cus_1"}, @config)

      assert received_request().path == "/v1/billing_portal/sessions"
    end
  end

  describe "retrieve_subscription/2" do
    test "GETs the subscription by id" do
      capture_request(%{"id" => "sub_1", "status" => "active"})

      assert {:ok, %{"status" => "active"}} = Stripe.retrieve_subscription("sub_1", @config)

      request = received_request()
      assert request.method == "GET"
      assert request.path == "/v1/subscriptions/sub_1"
    end
  end

  describe "retrieve_checkout_session/2" do
    test "GETs the session and expands line items" do
      capture_request(%{"id" => "cs_1", "status" => "complete"})

      assert {:ok, %{"status" => "complete"}} = Stripe.retrieve_checkout_session("cs_1", @config)

      request = received_request()
      assert request.path == "/v1/checkout/sessions/cs_1"
    end
  end

  describe "error mapping" do
    test "maps a non-2xx response to an http_status error" do
      Req.Test.stub(KilnCMS.Billing, fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{"error" => %{"code" => "card_declined"}})
      end)

      assert {:error, {:http_status, 402, body}} =
               Stripe.create_checkout_session(%{}, @config)

      assert body["error"]["code"] == "card_declined"
    end

    test "maps a 401 to an http_status error the facade can explain" do
      Req.Test.stub(KilnCMS.Billing, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
      end)

      assert {:error, {:http_status, 401, _body} = reason} =
               Stripe.retrieve_account(@config)

      assert KilnCMS.Billing.describe_error(reason) =~ "rejected these credentials"
    end

    test "passes a transport error through" do
      Req.Test.stub(KilnCMS.Billing, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} = Stripe.retrieve_subscription("sub_1", @config)
    end

    test "does not retry a failed POST" do
      # POSTs are money-moving and carry an idempotency key, so retry policy
      # belongs to the caller (Oban), not to Req.
      parent = self()

      Req.Test.stub(KilnCMS.Billing, fn conn ->
        send(parent, :attempt)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _reason} = Stripe.create_checkout_session(%{}, @config)

      assert_received :attempt
      refute_received :attempt
    end
  end
end
