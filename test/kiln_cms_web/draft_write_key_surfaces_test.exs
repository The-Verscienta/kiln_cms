defmodule KilnCMSWeb.DraftWriteKeySurfacesTest do
  @moduledoc """
  The `:draft_write` API-key scope (#2273) over the real HTTP surfaces: a
  `kiln_` bearer key creates a draft and edits it again on `/api/json` and
  `/gql`, and is refused on a published row. The PATCH is the case that needs
  the key to read its own draft, since the route loads the row as the actor.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-web-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint_key(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "svc",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: :draft_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "dw-web-#{System.unique_integer([:positive])}"

  defp json(method, path, key, attrs, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    body =
      case {method, attrs} do
        {_, nil} ->
          nil

        {:post, attrs} ->
          Jason.encode!(%{data: %{type: "post", attributes: attrs}})

        {:patch, attrs} ->
          Jason.encode!(%{
            data: %{type: "post", id: path |> String.split("/") |> Enum.at(4), attributes: attrs}
          })
      end

    conn =
      if body,
        do: dispatch(conn, @endpoint, method, path, body),
        else: dispatch(conn, @endpoint, method, path)

    {conn.status, if(conn.resp_body == "", do: %{}, else: Jason.decode!(conn.resp_body))}
  end

  defp gql(query, variables, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  setup do
    owner = user(:viewer)
    %{owner: owner, key: mint_key(owner)}
  end

  describe "JSON:API" do
    test "POST a draft, then PATCH it, with a real bearer key", %{owner: owner, key: key} do
      s = slug()

      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "From app", slug: s})

      created = CMS.get_post!(id, actor: user(:admin))
      assert created.state == :draft
      assert created.author_id == owner.id

      assert {200, %{"data" => %{"attributes" => %{"title" => "Edited"}}}} =
               json(:patch, "/api/json/posts/#{id}", key, %{title: "Edited"})

      assert CMS.get_post!(id, actor: user(:admin)).title == "Edited"
    end

    test "PATCH of a published row is refused", %{owner: owner, key: key} do
      published =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Live",
          slug: slug(),
          state: :published,
          author_id: owner.id
        })

      assert {status, _} =
               json(:patch, "/api/json/posts/#{published.id}", key, %{title: "Hijack"})

      assert status in [403, 404]
      assert CMS.get_post!(published.id, actor: user(:admin)).title == "Live"
    end

    test "PATCH of another author's draft is refused", %{key: key} do
      other =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Theirs",
          slug: slug(),
          state: :draft,
          author_id: user(:editor).id
        })

      assert {status, _} = json(:patch, "/api/json/posts/#{other.id}", key, %{title: "Mine"})
      assert status in [403, 404]
      assert CMS.get_post!(other.id, actor: user(:admin)).title == "Theirs"
    end

    test "publish, submit-for-review and DELETE of its own draft are refused", %{key: key} do
      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "D", slug: slug()})

      for {method, path} <- [
            {:patch, "/api/json/posts/#{id}/publish"},
            {:patch, "/api/json/posts/#{id}/submit-for-review"},
            {:delete, "/api/json/posts/#{id}"}
          ] do
        attrs = if method == :patch, do: %{}
        assert {403, _} = json(method, path, key, attrs), "#{method} #{path}"
      end

      assert CMS.get_post!(id, actor: user(:admin)).state == :draft
    end
  end

  describe "GraphQL" do
    @create """
    mutation ($input: CreatePostInput!) {
      createPost(input: $input) { result { id title } errors { message } }
    }
    """

    @update """
    mutation ($id: ID!, $input: UpdatePostInput!) {
      updatePost(id: $id, input: $input) { result { id title } errors { message } }
    }
    """

    test "create then update its own draft", %{owner: owner, key: key} do
      body = gql(@create, %{input: %{title: "GQL", slug: slug()}}, key)
      assert %{"id" => id} = body["data"]["createPost"]["result"]
      assert CMS.get_post!(id, actor: user(:admin)).author_id == owner.id

      body = gql(@update, %{id: id, input: %{title: "GQL edited"}}, key)
      assert body["data"]["updatePost"]["errors"] == []
      assert body["data"]["updatePost"]["result"]["title"] == "GQL edited"
    end

    test "update of a published row is refused", %{owner: owner, key: key} do
      published =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Live",
          slug: slug(),
          state: :published,
          author_id: owner.id
        })

      body = gql(@update, %{id: published.id, input: %{title: "Hijack"}}, key)
      assert is_nil(get_in(body, ["data", "updatePost", "result"]))
      assert CMS.get_post!(published.id, actor: user(:admin)).title == "Live"
    end
  end

  describe "provenance (#2273)" do
    alias KilnCMS.CMS.Changes.StampDraftWriteProvenance
    alias KilnCMS.CMS.ContentSerializer

    defp provenance(post),
      do: Map.take(post, [:created_via_key_id, :created_via_key_name, :on_behalf_of])

    test "a token draft records the key and the header, an editor's draft none",
         %{owner: owner, key: key} do
      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "Via key", slug: slug()}, [
                 {"x-kiln-on-behalf-of", "verscienta-user-42"}
               ])

      post = CMS.get_post!(id, actor: user(:admin))
      [api_key] = Accounts.list_api_keys!(owner.id, actor: user(:admin))

      assert provenance(post) == %{
               created_via_key_id: api_key.id,
               created_via_key_name: "svc",
               on_behalf_of: "verscienta-user-42"
             }

      editor_draft = CMS.create_post!(%{title: "Human", slug: slug()}, actor: user(:editor))

      assert provenance(editor_draft) ==
               %{created_via_key_id: nil, created_via_key_name: nil, on_behalf_of: nil}
    end

    test "an editor's key-less request ignores the header", %{key: _key} do
      editor = user(:editor)

      post =
        CMS.create_post!(%{title: "Human", slug: slug()},
          actor: editor,
          context: %{kiln_on_behalf_of: "someone"}
        )

      assert post.on_behalf_of == nil
    end

    test "no header leaves on_behalf_of empty but still records the key", %{key: key} do
      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "No header", slug: slug()})

      post = CMS.get_post!(id, actor: user(:admin))
      assert post.created_via_key_id
      assert post.on_behalf_of == nil
    end

    test "the header is sanitized and bounded", %{key: key} do
      long = String.duplicate("a", 500)

      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "Long", slug: slug()}, [
                 {"x-kiln-on-behalf-of", "  user\t7\u202E  " <> long}
               ])

      stored = CMS.get_post!(id, actor: user(:admin)).on_behalf_of
      assert String.length(stored) == StampDraftWriteProvenance.max_length()
      assert String.starts_with?(stored, "user7  aaa")
    end

    test "sanitize/1 strips control and format characters and rejects non-text" do
      assert StampDraftWriteProvenance.sanitize("a\r\nb\0c\u200Bd\u2028e") == "abcde"
      assert StampDraftWriteProvenance.sanitize("  \t ") == nil
      assert StampDraftWriteProvenance.sanitize(<<255, 254>>) == nil
      assert StampDraftWriteProvenance.sanitize(nil) == nil
      assert StampDraftWriteProvenance.sanitize(%{"a" => 1}) == nil
    end

    test "it cannot be written by a client or by an update", %{key: key} do
      # Not an attribute of the API: refused outright, never stored.
      assert {400, _} =
               json(:post, "/api/json/posts", key, %{
                 title: "Forge",
                 slug: slug(),
                 on_behalf_of: "forged",
                 created_via_key_name: "forged"
               })

      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "Real", slug: slug()})

      post = CMS.get_post!(id, actor: user(:admin))
      assert post.on_behalf_of == nil
      assert post.created_via_key_name == "svc"

      assert {200, _} =
               json(:patch, "/api/json/posts/#{id}", key, %{title: "Again"}, [
                 {"x-kiln-on-behalf-of", "later"}
               ])

      assert provenance(CMS.get_post!(id, actor: user(:admin))) == provenance(post)
    end

    test "survives the key being revoked and deleted", %{owner: owner, key: key} do
      assert {201, %{"data" => %{"id" => id}}} =
               json(:post, "/api/json/posts", key, %{title: "Orphan", slug: slug()}, [
                 {"x-kiln-on-behalf-of", "u1"}
               ])

      admin = user(:admin)
      [api_key] = Accounts.list_api_keys!(owner.id, actor: admin)
      Accounts.revoke_api_key!(api_key, actor: admin)
      import Ecto.Query

      {1, _} =
        KilnCMS.Repo.delete_all(
          from(k in "api_keys", where: k.id == type(^api_key.id, :binary_id))
        )

      post = CMS.get_post!(id, actor: admin)
      assert post.created_via_key_id == api_key.id
      assert post.created_via_key_name == "svc"
      assert post.on_behalf_of == "u1"
    end

    test "is on the key's own response, not the webhook payload or version history",
         %{key: key} do
      assert {201, %{"data" => %{"id" => id} = data}} =
               json(:post, "/api/json/posts", key, %{title: "Seen", slug: slug()}, [
                 {"x-kiln-on-behalf-of", "u9"}
               ])

      # The key sees the provenance of the draft it just made (and nobody else
      # without an editor tier; see `DraftWriteKeyProvenanceReadTest`).
      assert data["attributes"]["on_behalf_of"] == "u9"
      assert data["attributes"]["created_via_key_name"] == "svc"

      post = CMS.get_post!(id, actor: user(:admin))
      payload = ContentSerializer.to_map(post)
      refute Map.has_key?(payload, :on_behalf_of)
      refute Map.has_key?(payload, :created_via_key_name)
      refute Map.has_key?(payload, :created_via_key_id)

      [version] =
        CMS.Post.Version
        |> Ash.read!(actor: user(:admin))
        |> Enum.filter(&(&1.version_source_id == id and &1.version_action_name == :create))

      # Kept out of history: a second key on the same owner reads this
      # version (`DraftWriteOwnDrafts` is per owner), the provenance is per key.
      refute Map.has_key?(version.changes, "on_behalf_of")
      refute Map.has_key?(version.changes, :on_behalf_of)
    end

    test "GraphQL create records it too", %{key: key} do
      query = """
      mutation ($input: CreatePostInput!) {
        createPost(input: $input) { result { id } errors { message } }
      }
      """

      body =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("x-kiln-on-behalf-of", "gql-user")
        |> post(
          "/gql",
          Jason.encode!(%{query: query, variables: %{input: %{title: "G", slug: slug()}}})
        )
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      id = body["data"]["createPost"]["result"]["id"]
      assert CMS.get_post!(id, actor: user(:admin)).on_behalf_of == "gql-user"
    end
  end
end
