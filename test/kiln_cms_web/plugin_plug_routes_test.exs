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

  describe "the raw body, by content type (#2272)" do
    @json ~s({ "id" :"evt_1",  "note":"café — ünï" })
    @text "  line one\r\n{ id :evt_1 }  café "

    for {type, body} <- [
          {"application/json", :json},
          {"application/activity+json", :json},
          {"application/x-www-form-urlencoded", :form},
          {"text/plain", :text},
          {"text/plain; charset=utf-8", :text},
          {"application/octet-stream", :text},
          {"application/xml", :text},
          {"text/xml; charset=utf-8", :text},
          {"application/x-unheard-of", :text}
        ] do
      test "#{type}: the exact bytes reach the plug", %{conn: conn} do
        body = body(unquote(body))

        conn =
          conn
          |> put_req_header("content-type", unquote(type))
          |> post("/fixture-hooks/echo", body)

        assert response(conn, 200) == body
      end

      test "#{type}: over the 1 MB cap is a 413", %{conn: conn} do
        assert_over_cap(conn, unquote(type))
      end
    end

    test "a locale-prefixed plugin path gets the bytes too", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/fr/fixture-hooks/echo", @text)

      assert response(conn, 200) == @text
    end

    test "a parameterised plugin route gets the bytes", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/fixture-hooks/provider/acme", @text)

      assert response(conn, 200) == @text
    end

    test "a body with no content type is read under the same cap", %{conn: conn} do
      conn = post_without_content_type("/fixture-hooks/echo", @text)
      assert response(conn, 200) == @text
    end

    test "a body with no content type over the cap is a 413", %{conn: conn} do
      assert_over_cap(conn, nil)
    end

    test "the 413 body is JSON for a JSON client and plain text otherwise", %{conn: conn} do
      big = String.duplicate("a", KilnCMSWeb.Plugs.RawBodyReader.max_bytes() + 1)

      {413, _headers, html} =
        assert_error_sent(413, fn ->
          conn |> put_req_header("content-type", "text/plain") |> post("/fixture-hooks/echo", big)
        end)

      assert html =~ "Request Entity Too Large"

      {413, _headers, json} =
        assert_error_sent(413, fn ->
          conn
          |> put_req_header("content-type", "text/plain")
          |> put_req_header("accept", "application/json")
          |> post("/fixture-hooks/echo", big)
        end)

      assert %{"errors" => [%{"status" => "413"}]} = Jason.decode!(json)
    end

    test "an empty body is an empty string, not an error", %{conn: conn} do
      conn =
        conn |> put_req_header("content-type", "text/plain") |> post("/fixture-hooks/echo", "")

      assert response(conn, 200) == ""
    end

    test "params stay the query and path params; the body is not parsed", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/fixture-hooks/provider/acme?x=1", @text)

      assert conn.params == %{"name" => "acme", "x" => "1"}
    end

    test "multipart is parsed to params, not preserved (documented exception)", %{conn: conn} do
      body =
        "--B\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"

      conn =
        conn
        |> put_req_header("content-type", "multipart/form-data; boundary=B")
        |> post("/fixture-hooks/echo", body)

      assert conn.params["a"] == "1"
      assert response(conn, 200) == ""
    end

    test "a path no plugin mounts keeps leaving an unparsed type unread", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post("/nope/not-a-plugin", @text)

      refute conn.private[:raw_body]
    end

    test "a GET is untouched", %{conn: conn} do
      assert get(conn, "/fixture-hooks/ping").status == 200
    end

    defp body(:json), do: @json
    defp body(:form), do: "b=2&a=1&a=%C3%A9"
    defp body(:text), do: @text

    defp assert_over_cap(conn, type) do
      big = String.duplicate("a", KilnCMSWeb.Plugs.RawBodyReader.max_bytes() + 1)

      assert_error_sent 413, fn ->
        if type do
          conn |> put_req_header("content-type", type) |> post("/fixture-hooks/echo", big)
        else
          post_without_content_type("/fixture-hooks/echo", big)
        end
      end
    end

    # `Phoenix.ConnTest` refuses a binary body without a content type, which is
    # exactly the request under test — so build it with `Plug.Test`.
    defp post_without_content_type(path, body) do
      :post
      |> Plug.Test.conn(path, body)
      |> Plug.Conn.delete_req_header("content-type")
      |> Plug.Conn.put_private(:phoenix_endpoint, KilnCMSWeb.Endpoint)
      |> KilnCMSWeb.Endpoint.call(KilnCMSWeb.Endpoint.init([]))
    end
  end
end
