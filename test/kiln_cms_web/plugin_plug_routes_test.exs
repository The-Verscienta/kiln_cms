defmodule KilnCMSWeb.PluginPlugRoutesTest do
  @moduledoc """
  Plugin plug routes (`Kiln.Plugin.plug_routes/0`, #2272) through the real
  router and endpoint, using `KilnDepFixture.Plugin`: a plugin compiled as a
  Mix dependency, with only `plug` underneath it, whose controller-style routes
  and `forward` the core baked into `KilnCMSWeb.Router`.
  """
  use KilnCMSWeb.ConnCase, async: true

  describe "a route to a Plug" do
    test "GET reaches the plug", %{conn: conn} do
      conn = get(conn, "/fixture-hooks/ping")

      assert response(conn, 200) == "pong"
    end

    test "answers before the content-delivery catch-alls", %{conn: conn} do
      # `/:slug/:slug` would otherwise take this; the plugin path wins.
      assert get(conn, "/fixture-hooks/ping").status == 200
    end

    test "POST needs no CSRF token and no session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/fixture-hooks/echo", ~s({"a":1}))

      assert response(conn, 200) == ~s({"a":1})
      refute get_resp_header(conn, "set-cookie") |> Enum.any?(&(&1 =~ "_csrf"))
    end

    test "the exact request bytes reach the plug for a plugin path", %{conn: conn} do
      # What an HMAC is computed over: key order, spacing and non-ASCII intact.
      body = ~s({ "note" : "café — ünïcode",  "id":"evt_1" })

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/fixture-hooks/echo", body)

      assert response(conn, 200) == body
    end

    test "the tenant is resolved by the endpoint", %{conn: conn} do
      conn = get(conn, "/fixture-hooks/tenant")

      assert response(conn, 200) == to_string(KilnCMS.Accounts.default_org_id())
    end
  end

  describe "a forward" do
    test "hands the rest of the path to the plug", %{conn: conn} do
      conn = get(conn, "/fixture-forward/hello")

      assert response(conn, 200) == "hello from the forward"
    end

    test "the forwarded plug answers its own 404s", %{conn: conn} do
      conn = get(conn, "/fixture-forward/nope")

      assert response(conn, 404) == "no such feed"
    end
  end

  describe "rate limiting" do
    test "plugin routes charge the :plugin_endpoint bucket", %{conn: conn} do
      {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :plugin_endpoint)
      key = KilnCMSWeb.RateLimit.client_key(conn.remote_ip)

      # Spend the address's whole budget directly, then show the route is
      # refused by it — not merely by `:api`.
      for _ <- 1..limit, do: KilnCMSWeb.RateLimit.check(:plugin_endpoint, key)

      assert get(conn, "/fixture-hooks/ping").status == 429
      assert get(conn, "/fixture-forward/hello").status == 429
    end

    test "the production limit is 300 a minute per address" do
      assert %{plugin_endpoint: {300, 60_000}} =
               Map.take(KilnCMSWeb.RateLimit.default_limits(), [:plugin_endpoint])
    end
  end
end
