defmodule KilnCMSWeb.Plugs.PublicCacheTest do
  @moduledoc """
  Anonymous reads of JSON:API, GraphQL `GET` and `/api/search` are CDN-cacheable
  (`public` + a body ETag + 304s); a request carrying any credential stays
  `private, no-store`, because an editor's token sees drafts on the same URLs.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMSWeb.Plugs.PublicCache

  @accept "application/vnd.api+json"
  @password "password123456"
  @public "public, max-age=60, stale-while-revalidate=60"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pc-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp slug, do: "pc-#{System.unique_integer([:positive])}"

  defp published_post(admin, attrs \\ %{}) do
    %{title: "Cached", slug: slug()}
    |> Map.merge(attrs)
    |> CMS.create_post!(actor: admin)
    |> then(&CMS.publish_post!(&1, %{}, actor: admin))
  end

  defp jsonapi(conn \\ build_conn(), path),
    do: conn |> put_req_header("accept", @accept) |> get(path)

  defp header(conn, name), do: get_resp_header(conn, name)

  defp vary(conn) do
    conn |> header("vary") |> Enum.flat_map(&String.split(&1, ", "))
  end

  describe "JSON:API, anonymous" do
    test "is public with a strong body ETag, a Vary and the site's surrogate key" do
      post = published_post(user(:admin))
      conn = jsonapi("/api/json/posts?filter[slug]=#{post.slug}")

      assert conn.status == 200
      assert header(conn, "cache-control") == [@public]
      assert [etag] = header(conn, "etag")
      # Weak, so Bandit still gzips it (it skips a strong-ETag response).
      assert etag =~ ~r/^W\/"[A-Za-z0-9_-]{22}"$/
      assert Enum.all?(~w(accept authorization origin), &(&1 in vary(conn)))
      assert length(header(conn, "vary")) == 1

      org_id = conn.assigns.current_org.id
      assert header(conn, "surrogate-key") == ["kiln kiln-org-#{org_id}"]
      assert header(conn, "cache-tag") == ["kiln,kiln-org-#{org_id}"]
    end

    test "a matching If-None-Match is a bodyless 304 carrying the same validators" do
      post = published_post(user(:admin))
      path = "/api/json/posts?filter[slug]=#{post.slug}"
      [etag] = path |> jsonapi() |> header("etag")

      opaque = String.replace_prefix(etag, "W/", "")

      for presented <- [etag, opaque, ~s("nope", #{etag}), "*"] do
        conn = build_conn() |> put_req_header("if-none-match", presented) |> jsonapi(path)

        assert conn.status == 304, "expected 304 for If-None-Match: #{presented}"
        assert conn.resp_body == ""
        assert header(conn, "etag") == [etag]
        assert header(conn, "cache-control") == [@public]
        assert "authorization" in vary(conn)
      end

      stale = build_conn() |> put_req_header("if-none-match", ~s("nope")) |> jsonapi(path)
      assert stale.status == 200
    end

    # #1079: an ETag keyed on a subset of the inputs 304'd a caller into a body
    # that had since changed. A digest of the body cannot miss one.
    test "a live edit changes the ETag, so the old one no longer 304s" do
      admin = user(:admin)
      post = published_post(admin)
      path = "/api/json/posts?filter[slug]=#{post.slug}"
      [before] = path |> jsonapi() |> header("etag")

      CMS.update_post!(post, %{title: "Edited live"}, actor: admin)

      conn = build_conn() |> put_req_header("if-none-match", before) |> jsonapi(path)
      assert conn.status == 200
      assert conn.resp_body =~ "Edited live"
      assert [after_edit] = header(conn, "etag")
      refute after_edit == before
    end

    test "a non-200 keeps Plug's private default and gets no ETag" do
      conn = jsonapi("/api/json/posts/#{Ecto.UUID.generate()}")

      assert conn.status == 404
      assert header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
      assert header(conn, "etag") == []
    end
  end

  describe "JSON:API, with a credential" do
    test "an editor's bearer token sees drafts, so the response is private, no-store" do
      admin = user(:admin)
      draft = CMS.create_post!(%{title: "Draft", slug: slug()}, actor: admin)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token(user(:editor))}")
        |> jsonapi("/api/json/posts?filter[slug]=#{draft.slug}")

      assert conn.status == 200
      assert conn.resp_body =~ draft.id
      assert header(conn, "cache-control") == ["private, no-store"]
      assert header(conn, "etag") == []
      assert header(conn, "surrogate-key") == []
      assert "authorization" in vary(conn)
    end

    test "an unverifiable bearer token is still not anonymous" do
      post = published_post(user(:admin))

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer not-a-jwt")
        |> jsonapi("/api/json/posts?filter[slug]=#{post.slug}")

      assert conn.status == 200
      assert header(conn, "cache-control") == ["private, no-store"]
    end

    test "an unlock grant, x-api-key or cookie is not anonymous either" do
      post = published_post(user(:admin))
      path = "/api/json/posts?filter[slug]=#{post.slug}"

      for credentialed <- [
            put_req_header(build_conn(), "x-kiln-unlock", "grant"),
            put_req_header(build_conn(), "x-api-key", "kiln_x"),
            put_req_header(build_conn(), "cookie", "_kiln_cms_key=abc")
          ] do
        conn = jsonapi(credentialed, path)
        assert header(conn, "cache-control") == ["private, no-store"]
        assert header(conn, "etag") == []
      end

      conn = jsonapi(path <> "&unlock=grant")
      assert header(conn, "cache-control") == ["private, no-store"]
    end

    test "a presented If-None-Match never 304s a credentialed request" do
      post = published_post(user(:admin))
      path = "/api/json/posts?filter[slug]=#{post.slug}"
      [etag] = path |> jsonapi() |> header("etag")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token(user(:editor))}")
        |> put_req_header("if-none-match", etag)
        |> jsonapi(path)

      assert conn.status == 200
    end
  end

  describe "GraphQL" do
    test "an anonymous GET query is public, with an ETag and a 304" do
      conn = get(build_conn(), "/gql", %{"query" => "{ health }"})

      assert json_response(conn, 200) == %{"data" => %{"health" => "ok"}}
      assert header(conn, "cache-control") == [@public]
      assert [etag] = header(conn, "etag")

      again =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/gql", %{"query" => "{ health }"})

      assert again.status == 304
      assert again.resp_body == ""
    end

    test "an anonymous GET is also cached through the forward (`/gql/…`)" do
      conn = get(build_conn(), "/gql/query", %{"query" => "{ health }"})

      assert conn.status == 200
      assert header(conn, "cache-control") == [@public]
    end

    # Absinthe falls back to the request body for the document when the URL
    # names none, which would store an arbitrary query's answer under this URL.
    test "a GET whose document is not in the URL is never public" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :get, "/gql/x", ~s({"query": "{ health }"}))

      refute header(conn, "cache-control") == [@public]
      assert header(conn, "etag") == []
    end

    test "a query that answers with `errors` is not pinned" do
      conn = get(build_conn(), "/gql", %{"query" => "{ noSuchField }"})

      assert %{"errors" => [_ | _]} = Jason.decode!(conn.resp_body)
      refute header(conn, "cache-control") == [@public]
      assert header(conn, "etag") == []
    end

    test "a mutation over GET is refused and never cached" do
      conn =
        get(build_conn(), "/gql", %{
          "query" => ~s|mutation { createPost(input: {title: "x", slug: "x"}) { result { id } } }|
        })

      assert conn.status == 405
      refute header(conn, "cache-control") == [@public]
      assert header(conn, "etag") == []
    end

    test "a POST is never public, even anonymous" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/gql", ~s({"query": "{ health }"}))

      assert json_response(conn, 200)
      refute header(conn, "cache-control") == [@public]
      assert header(conn, "etag") == []
      assert "authorization" in vary(conn)
    end

    test "a GET with a bearer token is private, no-store" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token(user(:editor))}")
        |> get("/gql", %{"query" => "{ health }"})

      assert conn.status == 200
      assert header(conn, "cache-control") == ["private, no-store"]
      assert header(conn, "etag") == []
    end
  end

  describe "/api/search" do
    test "anonymous is public; a bearer token is private, no-store" do
      anonymous = get(build_conn(), "/api/search", %{"q" => "cached"})
      assert anonymous.status == 200
      assert header(anonymous, "cache-control") == [@public]
      assert [_etag] = header(anonymous, "etag")

      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token(user(:editor))}")
        |> get("/api/search", %{"q" => "cached"})

      assert authed.status == 200
      assert header(authed, "cache-control") == ["private, no-store"]
    end
  end

  # The plug on a bare conn: the rules that no route above isolates.
  describe "the plug in isolation" do
    defp run(conn, opts \\ []), do: PublicCache.call(conn, PublicCache.init(opts))

    defp bare, do: Plug.Test.conn(:get, "/api/x")

    test "a handler's own cache-control is never overridden" do
      conn =
        bare()
        |> run()
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, "experiment arm")

      assert header(conn, "cache-control") == ["private, no-store"]
      assert header(conn, "etag") == []
    end

    test "a response that sets a cookie is not public" do
      conn =
        bare()
        |> run()
        |> put_resp_cookie("k", "v")
        |> send_resp(200, "body")

      refute header(conn, "cache-control") == [@public]
    end

    test "every existing Vary is folded into one header" do
      conn =
        bare()
        |> run()
        |> prepend_resp_headers([{"vary", "origin"}])
        |> prepend_resp_headers([{"vary", "Accept, x-thing"}])
        |> send_resp(200, "body")

      assert [single] = header(conn, "vary")

      assert single |> String.split(", ") |> Enum.sort() ==
               ~w(accept authorization origin x-thing)

      assert length(String.split(single, "origin")) == 2
    end

    test "the ETag covers the content type as well as the body" do
      etag = fn type ->
        bare()
        |> run()
        |> put_resp_content_type(type)
        |> send_resp(200, "same")
        |> header("etag")
      end

      refute etag.("application/json") == etag.("text/markdown")
    end

    test "a GET that declares a body is never public" do
      conn =
        bare()
        |> put_req_header("content-length", "12")
        |> run()
        |> send_resp(200, "body")

      refute header(conn, "cache-control") == [@public]
    end

    test "a session about to be written counts as setting a cookie" do
      conn =
        bare()
        |> run()
        |> put_private(:plug_session_info, :write)
        |> send_resp(200, "body")

      refute header(conn, "cache-control") == [@public]
    end

    test "a chunked response is left alone" do
      conn = bare() |> run() |> send_chunked(200)

      refute header(conn, "cache-control") == [@public]
      assert header(conn, "etag") == []
    end

    test "`enabled: false` turns public marking off; max-age and SWR are config" do
      assert PublicCache.cache_control(enabled: false) == nil
      assert PublicCache.cache_control([]) == @public

      assert PublicCache.cache_control(max_age: 300, stale_while_revalidate: 30) ==
               "public, max-age=300, stale-while-revalidate=30"
    end
  end
end
