defmodule KilnCMSWeb.PluginPlugRoutesTest do
  @moduledoc """
  Plugin plug routes (`Kiln.Plugin.plug_routes/0`, #2272) through the real
  router and endpoint, using `KilnDepFixture.Plugin`: a plugin compiled as a
  Mix dependency, with only `plug` underneath it, whose controller-style routes
  and `forward` the core baked into `KilnCMSWeb.Router`.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.{Accounts, CMS}

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

    test "a body with no content type is read under the same cap", %{conn: _conn} do
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

  # The worked example in docs/plugin-extensibility.md ("A webhook receiver"):
  # the plugin authenticates its own caller, takes the tenant from the request's
  # org, and acts as an explicit service-account actor. Application env is
  # global, so this module is not async.
  describe "webhook receiver (HMAC, tenant, explicit actor)" do
    @secret "whsec_test_" <> String.duplicate("k", 24)
    @body ~s({ "id": "evt_1A", "title": "Café — order #1" })

    setup do
      org = KilnCMS.OrgFixtures.org("hook")
      editor = user!(:editor)
      # The actor's authority is a membership of *this* org; it has none on the
      # default org, so its tenant-bound reach is real.
      member!(editor, org.id, :editor)
      configure(editor)

      %{org: org, editor: editor, admin: user!(:admin)}
    end

    test "a signed delivery on an org host writes a draft in that org as the actor", ctx do
      conn = ctx.conn |> org_conn(ctx.org) |> deliver(@body)

      assert id = response(conn, 201)
      assert [%{id: ^id, title: "Café — order #1"}] = posts(ctx.admin, ctx.org)
      # Not in the default org: the tenant is the request's, not the fallback.
      assert posts(ctx.admin, Accounts.default_org_id()) == []
    end

    test "a redelivery finds the draft the first one wrote", ctx do
      conn = org_conn(ctx.conn, ctx.org)
      first = conn |> deliver(@body) |> response(201)
      second = conn |> recycle() |> org_conn(ctx.org) |> deliver(@body) |> response(200)

      assert first == second
      assert [_one] = posts(ctx.admin, ctx.org)
    end

    test "the same actor is refused on a host whose org it does not belong to", ctx do
      # A valid signature, a valid actor, the wrong tenant: the resource's own
      # policies refuse, and nothing is written anywhere.
      conn = deliver(ctx.conn, @body)

      assert response(conn, 403) == "forbidden"
      assert posts(ctx.admin, Accounts.default_org_id()) == []
      assert posts(ctx.admin, ctx.org) == []
    end

    test "an actor who belongs to the default org writes there", ctx do
      member!(ctx.editor, Accounts.default_org_id(), :editor)

      assert ctx.conn |> deliver(@body) |> response(201)
      assert [_one] = posts(ctx.admin, Accounts.default_org_id())
    end

    test "a missing, wrong or stale signature is a 401 and writes nothing", ctx do
      conn = org_conn(ctx.conn, ctx.org)

      assert conn |> deliver(@body, nil) |> response(401)

      assert conn
             |> recycle()
             |> org_conn(ctx.org)
             |> deliver(@body, "sha256=00")
             |> response(401)

      # Signed for another body: a re-serialised payload no longer verifies.
      stale = sign(@secret, ~s({"id":"evt_1A","title":"Café — order #1"}))
      assert conn |> recycle() |> org_conn(ctx.org) |> deliver(@body, stale) |> response(401)

      assert posts(ctx.admin, ctx.org) == []
    end

    test "a signed body that is not JSON verifies, then is a 422", ctx do
      conn =
        ctx.conn
        |> org_conn(ctx.org)
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("x-fixture-signature", sign(@secret, "hi"))
        |> post("/fixture-hooks/webhook", "hi")

      assert response(conn, 422)
      assert posts(ctx.admin, ctx.org) == []
    end

    test "a multipart body has no raw body to verify: 400", ctx do
      body = "--B\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"

      conn =
        ctx.conn
        |> org_conn(ctx.org)
        |> put_req_header("content-type", "multipart/form-data; boundary=B")
        |> put_req_header("x-fixture-signature", sign(@secret, body))
        |> post("/fixture-hooks/webhook", body)

      assert response(conn, 400)
    end

    test "a signed body without the expected fields is a 422", ctx do
      body = ~s({"nope":true})

      assert ctx.conn |> org_conn(ctx.org) |> deliver(body) |> response(422)
    end

    test "an unconfigured hook refuses rather than accepting anyone", ctx do
      Application.delete_env(:kiln_dep_fixture, :webhook)

      assert ctx.conn |> org_conn(ctx.org) |> deliver(@body) |> response(503)
    end
  end

  defp deliver(conn, body, signature \\ :sign) do
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      case signature do
        :sign -> put_req_header(conn, "x-fixture-signature", sign(@secret, body))
        nil -> conn
        given -> put_req_header(conn, "x-fixture-signature", given)
      end

    post(conn, "/fixture-hooks/webhook", body)
  end

  defp sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp configure(actor) do
    Application.put_env(:kiln_dep_fixture, :webhook, secret: @secret, actor_id: actor.id)
    on_exit(fn -> Application.delete_env(:kiln_dep_fixture, :webhook) end)
  end

  defp posts(admin, tenant), do: CMS.list_posts!(actor: admin, tenant: tenant)

  defp user!(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "hook-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role,
      audiences: []
    })
  end
end
