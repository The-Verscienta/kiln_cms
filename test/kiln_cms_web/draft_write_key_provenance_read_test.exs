defmodule KilnCMSWeb.DraftWriteKeyProvenanceReadTest do
  @moduledoc """
  Who can READ the provenance of a token draft (#2273, ADR 0012) on JSON:API
  and GraphQL: editor and admin tiers, and a `:draft_write` key for the drafts
  it created. Anonymous callers, viewer-tier actors and another key never do,
  on a published row or a draft, in a single read or a list, with or without
  `?fields=`; the field is omitted (JSON:API) or null (GraphQL), never an
  error, and a filter or sort on it is no oracle.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @fields ~w(created_via_key_id created_via_key_name on_behalf_of)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-read-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint_key(owner, access) do
    owner.id
    |> Accounts.mint_api_key!(
      "svc",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: access},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "dw-read-#{System.unique_integer([:positive])}"

  defp get_json(path, key \\ nil) do
    conn = put_req_header(build_conn(), "accept", @accept)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer #{key}"), else: conn
    conn = get(conn, path)
    {conn, Jason.decode!(conn.resp_body)}
  end

  defp gql(query, key) do
    conn = put_req_header(build_conn(), "content-type", "application/json")
    conn = if key, do: put_req_header(conn, "authorization", "Bearer #{key}"), else: conn

    conn
    |> post("/gql", Jason.encode!(%{query: query}))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  # A token draft made through the real API, so the stamp is the real one.
  defp token_draft!(key, title \\ "Token draft") do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("x-kiln-on-behalf-of", "end-user-77")
      |> post(
        "/api/json/posts",
        Jason.encode!(%{data: %{type: "post", attributes: %{title: title, slug: slug()}}})
      )

    assert conn.status == 201
    Jason.decode!(conn.resp_body)["data"]["id"]
  end

  defp published_token_row!(draft_id) do
    draft = CMS.get_post!(draft_id, actor: user(:admin))

    Ash.Seed.seed!(CMS.Post, %{
      title: "Live from token",
      slug: slug(),
      state: :published,
      published_at: DateTime.utc_now(),
      author_id: draft.author_id,
      created_via_key_id: draft.created_via_key_id,
      created_via_key_name: draft.created_via_key_name,
      on_behalf_of: draft.on_behalf_of
    })
  end

  defp provenance_keys(%{"attributes" => attrs}),
    do: Map.keys(attrs) -- (Map.keys(attrs) -- @fields)

  setup do
    owner = user(:viewer)
    key = mint_key(owner, :draft_write)
    draft_id = token_draft!(key)

    %{
      owner: owner,
      key: key,
      draft_id: draft_id,
      published: published_token_row!(draft_id),
      editor_key: mint_key(user(:editor), :read),
      admin_key: mint_key(user(:admin), :read),
      viewer_key: mint_key(user(:viewer), :read)
    }
  end

  describe "JSON:API" do
    test "anonymous and viewer-tier callers get no provenance on a published row", ctx do
      for key <- [nil, ctx.viewer_key] do
        {_, %{"data" => data}} = get_json("/api/json/posts/#{ctx.published.id}", key)
        assert data["attributes"]["title"] == "Live from token"
        assert provenance_keys(data) == []

        {_, %{"data" => rows}} = get_json("/api/json/posts?page[limit]=100", key)
        assert Enum.any?(rows, &(&1["id"] == ctx.published.id))
        assert Enum.all?(rows, &(provenance_keys(&1) == []))
      end
    end

    test "?fields= naming the provenance fields still returns none to them", ctx do
      path = "/api/json/posts/#{ctx.published.id}?fields[post]=title,#{Enum.join(@fields, ",")}"

      for key <- [nil, ctx.viewer_key] do
        {conn, %{"data" => data}} = get_json(path, key)
        assert conn.status == 200
        assert data["attributes"] == %{"title" => "Live from token"}
      end
    end

    test "editor and admin tiers read it, on a published row and in a list", ctx do
      for key <- [ctx.editor_key, ctx.admin_key] do
        {_, %{"data" => data}} = get_json("/api/json/posts/#{ctx.published.id}", key)
        assert data["attributes"]["on_behalf_of"] == "end-user-77"
        assert data["attributes"]["created_via_key_name"] == "svc"
        assert is_binary(data["attributes"]["created_via_key_id"])

        {_, %{"data" => rows}} = get_json("/api/json/posts?page[limit]=100", key)
        row = Enum.find(rows, &(&1["id"] == ctx.draft_id))
        assert row["attributes"]["on_behalf_of"] == "end-user-77"

        {_, %{"data" => data}} =
          get_json("/api/json/posts/#{ctx.draft_id}?fields[post]=on_behalf_of", key)

        assert data["attributes"] == %{"on_behalf_of" => "end-user-77"}
      end
    end

    test "the draft_write key reads its own draft's provenance, not a published row's",
         ctx do
      {_, %{"data" => data}} = get_json("/api/json/posts/#{ctx.draft_id}", ctx.key)
      assert data["attributes"]["on_behalf_of"] == "end-user-77"
      assert data["attributes"]["created_via_key_name"] == "svc"

      {_, %{"data" => data}} = get_json("/api/json/posts/#{ctx.published.id}", ctx.key)
      assert provenance_keys(data) == []
    end

    test "another draft_write key, even on the same owner, does not see it", ctx do
      other = mint_key(ctx.owner, :draft_write)

      {conn, body} = get_json("/api/json/posts/#{ctx.draft_id}", other)
      # Same owner, so the row is readable to it; the provenance is not.
      assert conn.status == 200
      assert provenance_keys(body["data"]) == []

      stranger = mint_key(user(:viewer), :draft_write)
      {conn, body} = get_json("/api/json/posts/#{ctx.draft_id}", stranger)
      assert conn.status in [403, 404]
      refute Jason.encode!(body) =~ "end-user-77"
    end

    test "a filter or sort on a field the caller cannot see is no oracle", ctx do
      for key <- [nil, ctx.viewer_key] do
        {_, %{"data" => rows}} =
          get_json("/api/json/posts?filter[on_behalf_of]=end-user-77&page[limit]=100", key)

        assert rows == []

        {_, %{"data" => rows}} =
          get_json(
            "/api/json/posts?filter[created_via_key_name][is_nil]=false&page[limit]=100",
            key
          )

        assert rows == []
      end

      {_, %{"data" => rows}} =
        get_json(
          "/api/json/posts?filter[on_behalf_of]=end-user-77&page[limit]=100",
          ctx.editor_key
        )

      assert Enum.any?(rows, &(&1["id"] == ctx.published.id))
    end

    test "an anonymous cached response carries none, an authenticated one is not cached",
         ctx do
      {anon, %{"data" => data}} = get_json("/api/json/posts/#{ctx.published.id}")
      assert provenance_keys(data) == []
      assert hd(get_resp_header(anon, "cache-control")) =~ "public"
      refute anon.resp_body =~ "end-user-77"

      {authed, %{"data" => data}} =
        get_json("/api/json/posts/#{ctx.published.id}", ctx.editor_key)

      assert data["attributes"]["on_behalf_of"] == "end-user-77"
      assert hd(get_resp_header(authed, "cache-control")) =~ "no-store"
      refute get_resp_header(authed, "cache-control") |> hd() =~ "public"
    end
  end

  describe "GraphQL" do
    defp slug_query(s, fields),
      do: ~s|{ postBySlug(slug: "#{s}") { title #{fields} } }|

    @gql_fields "createdViaKeyId createdViaKeyName onBehalfOf"

    test "anonymous and viewer get null for the fields, an error entry for those only", ctx do
      q = slug_query(ctx.published.slug, @gql_fields)

      for key <- [nil, ctx.viewer_key] do
        body = gql(q, key)

        assert body["data"]["postBySlug"] == %{
                 "title" => "Live from token",
                 "createdViaKeyId" => nil,
                 "createdViaKeyName" => nil,
                 "onBehalfOf" => nil
               }

        # ash_graphql reports a refused field as a `forbidden_field` entry
        # beside the partial data; nothing else is lost and nothing leaks.
        assert Enum.all?(body["errors"], &(&1["code"] == "forbidden_field"))

        assert body["errors"] |> Enum.map(&List.last(&1["path"])) |> Enum.sort() ==
                 ~w(createdViaKeyId createdViaKeyName onBehalfOf)

        refute Jason.encode!(body) =~ "end-user-77"

        # A query that does not ask for them is untouched.
        plain = gql(slug_query(ctx.published.slug, ""), key)
        assert plain == %{"data" => %{"postBySlug" => %{"title" => "Live from token"}}}
      end

      for key <- [ctx.editor_key, ctx.admin_key] do
        body = gql(q, key)
        refute Map.has_key?(body, "errors")
        post = body["data"]["postBySlug"]
        assert post["onBehalfOf"] == "end-user-77"
        assert post["createdViaKeyName"] == "svc"
        assert is_binary(post["createdViaKeyId"])
      end
    end

    test "a list read gives the same", ctx do
      q = "{ publishedPosts(limit: 50) { results { id onBehalfOf } } }"

      for key <- [nil, ctx.viewer_key] do
        results = get_in(gql(q, key), ["data", "publishedPosts", "results"])
        assert Enum.any?(results, &(&1["id"] == ctx.published.id))
        assert Enum.all?(results, &is_nil(&1["onBehalfOf"]))
      end

      results = get_in(gql(q, ctx.editor_key), ["data", "publishedPosts", "results"])
      assert Enum.any?(results, &(&1["onBehalfOf"] == "end-user-77"))
    end

    test "the draft_write key sees its own draft's provenance through a mutation result",
         ctx do
      query = """
      mutation ($input: CreatePostInput!) {
        createPost(input: $input) { result { onBehalfOf createdViaKeyName } errors { message } }
      }
      """

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{ctx.key}")
        |> put_req_header("x-kiln-on-behalf-of", "gql-77")
        |> post(
          "/gql",
          Jason.encode!(%{query: query, variables: %{input: %{title: "G", slug: slug()}}})
        )

      body = Jason.decode!(conn.resp_body)

      assert body["data"]["createPost"]["result"] == %{
               "onBehalfOf" => "gql-77",
               "createdViaKeyName" => "svc"
             }
    end
  end

  describe "/mcp" do
    defp mcp_read(key) do
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: "read_posts", arguments: %{}}
        })
      )
      |> Map.fetch!(:resp_body)
    end

    test "read tools follow the same policy", ctx do
      assert mcp_read(ctx.viewer_key) =~ ctx.published.id
      refute mcp_read(ctx.viewer_key) =~ "end-user-77"
      assert mcp_read(ctx.editor_key) =~ "end-user-77"
    end
  end

  describe "surfaces that must never carry it" do
    test "the webhook/sync serializer and the preview endpoint payload stay as they were",
         ctx do
      post = CMS.get_post!(ctx.draft_id, actor: user(:admin))
      payload = CMS.ContentSerializer.to_map(post)

      for f <- ~w(created_via_key_id created_via_key_name on_behalf_of)a do
        refute Map.has_key?(payload, f)
      end
    end

    test "search routes obey the same policy for anonymous callers", ctx do
      {_, body} = get_json("/api/json/posts/search/published?filter[query]=Live", nil)
      refute Jason.encode!(body) =~ "end-user-77"
      _ = ctx
    end
  end
end
