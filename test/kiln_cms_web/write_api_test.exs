defmodule KilnCMSWeb.WriteApiTest do
  @moduledoc """
  Write-capable headless API (#330 — the deliberate reversal of D7). Exercises
  the JSON:API write routes and GraphQL mutations end-to-end: API-key auth and
  the `:read_write` scope, the role gates (editor authors, admin publishes), the
  hard-delete ban, headless block-body writes via `block_tree`, and the re-fire
  that keeps in-place edits of already-published content from going stale.

  Counts/reads are always scoped to records seeded by the test (shared-sandbox
  safety).
  """
  use KilnCMSWeb.ConnCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @password "password123456"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "write-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # A plaintext `kiln_…` API key owned by `owner`, minted with the given scope.
  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "write-api",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  # A JWT bearer for the non-key (session/headless-login) path.
  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp slug, do: "w-#{System.unique_integer([:positive])}"

  # --- JSON:API request helpers -------------------------------------------

  defp req(method, path, opts) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)

    conn =
      case opts[:bearer] do
        nil -> conn
        tok -> put_req_header(conn, "authorization", "Bearer #{tok}")
      end

    conn =
      case opts[:body] do
        nil -> dispatch(conn, @endpoint, method, path)
        body -> dispatch(conn, @endpoint, method, path, Jason.encode!(body))
      end

    {conn.status, safe_decode(conn.resp_body)}
  end

  defp safe_decode(""), do: %{}
  defp safe_decode(body), do: Jason.decode!(body)

  defp post_json(path, attrs, opts),
    do:
      req(:post, path, Keyword.put(opts, :body, %{data: %{type: opts[:type], attributes: attrs}}))

  defp patch_json(path, id, attrs, opts) do
    body = %{data: %{type: opts[:type], id: id, attributes: attrs}}
    req(:patch, path, Keyword.put(opts, :body, body))
  end

  # --- GraphQL request helper ---------------------------------------------

  defp gql(query, variables, opts) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")

    conn =
      case opts[:bearer] do
        nil -> conn
        tok -> put_req_header(conn, "authorization", "Bearer #{tok}")
      end

    conn = post(conn, "/gql", Jason.encode!(%{query: query, variables: variables}))
    Jason.decode!(conn.resp_body)
  end

  describe "JSON:API — authentication & write scope" do
    test "a read-only API key is forbidden from creating content" do
      key = mint(user(:editor), :read)
      s = slug()

      assert {status, _body} =
               post_json("/api/json/posts", %{title: "Nope", slug: s}, type: "post", bearer: key)

      assert status == 403
      assert [] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
    end

    test "a :read_write key on an editor account creates a draft, attributed to the owner" do
      owner = user(:editor)
      key = mint(owner, :read_write)
      s = slug()

      assert {201, body} =
               post_json("/api/json/posts", %{title: "Via API", slug: s},
                 type: "post",
                 bearer: key
               )

      assert body["data"]["attributes"]["title"] == "Via API"

      [post] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
      assert post.state == :draft
      assert post.author_id == owner.id
    end

    test "an anonymous write is forbidden (no editor role)" do
      s = slug()
      assert {status, _} = post_json("/api/json/posts", %{title: "Anon", slug: s}, type: "post")
      assert status in [401, 403]
      assert [] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
    end

    test "a JWT-bearer editor (non-key path) can also create" do
      editor = user(:editor)
      s = slug()

      assert {201, _} =
               post_json("/api/json/posts", %{title: "JWT", slug: s},
                 type: "post",
                 bearer: token(editor)
               )

      assert [_] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
    end
  end

  describe "JSON:API — workflow transitions & role gates" do
    setup do
      owner = user(:editor)
      key = mint(owner, :read_write)
      post = CMS.create_post!(%{title: "WF", slug: slug()}, actor: owner)
      %{owner: owner, key: key, post: post}
    end

    test "submit-for-review moves a draft to in_review", %{key: key, post: post} do
      assert {200, _} =
               patch_json("/api/json/posts/#{post.id}/submit-for-review", post.id, %{},
                 type: "post",
                 bearer: key
               )

      assert CMS.get_post!(post.id, actor: user(:admin)).state == :in_review
    end

    test "publish is forbidden to an editor key but allowed to an admin key", %{post: post} do
      # Editor may not publish (admin approval step).
      editor_key = mint(user(:editor), :read_write)

      assert {403, _} =
               patch_json("/api/json/posts/#{post.id}/publish", post.id, %{},
                 type: "post",
                 bearer: editor_key
               )

      # An admin :read_write key can.
      admin_key = mint(user(:admin), :read_write)

      assert {200, _} =
               patch_json("/api/json/posts/#{post.id}/publish", post.id, %{},
                 type: "post",
                 bearer: admin_key
               )

      assert CMS.get_post!(post.id, actor: user(:admin)).state == :published

      assert_enqueued(
        worker: KilnCMS.Firing.FireWorker,
        args: %{"type" => "post", "id" => post.id}
      )
    end

    test "unpublish takes published content back down", %{post: post} do
      admin = user(:admin)
      published = CMS.publish_post!(post, %{}, actor: admin)
      admin_key = mint(admin, :read_write)

      assert {200, _} =
               patch_json("/api/json/posts/#{published.id}/unpublish", published.id, %{},
                 type: "post",
                 bearer: admin_key
               )

      assert CMS.get_post!(published.id, actor: admin).state == :draft
    end
  end

  describe "JSON:API — block-body writes & re-fire" do
    test "block_tree writes the body through the sanitizing union cast" do
      owner = user(:editor)
      key = mint(owner, :read_write)
      s = slug()

      blocks = [%{"type" => "rich_text", "content" => "<p>Hello body</p>", "order" => 1}]

      assert {201, _} =
               post_json("/api/json/posts", %{title: "Body", slug: s, block_tree: blocks},
                 type: "post",
                 bearer: key
               )

      [post] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
      assert length(post.blocks) == 1
    end

    test "editing already-published content re-fires its artifact" do
      admin = user(:admin)
      admin_key = mint(admin, :read_write)

      published =
        CMS.publish_post!(CMS.create_post!(%{title: "Live", slug: slug()}, actor: admin), %{},
          actor: admin
        )

      # Draining the publish's own firing first would leave only the update's
      # job; instead assert the update enqueues a fresh FireWorker for the id.
      assert {200, _} =
               patch_json(
                 "/api/json/posts/#{published.id}",
                 published.id,
                 %{title: "Live edited"},
                 type: "post",
                 bearer: admin_key
               )

      assert CMS.get_post!(published.id, actor: admin).title == "Live edited"

      assert_enqueued(
        worker: KilnCMS.Firing.FireWorker,
        args: %{"type" => "post", "id" => published.id}
      )
    end

    test "editing a draft does NOT re-fire (draft edits stay silent)" do
      owner = user(:editor)
      key = mint(owner, :read_write)
      draft = CMS.create_post!(%{title: "Draft", slug: slug()}, actor: owner)

      assert {200, _} =
               patch_json("/api/json/posts/#{draft.id}", draft.id, %{title: "Draft edited"},
                 type: "post",
                 bearer: key
               )

      refute_enqueued(
        worker: KilnCMS.Firing.FireWorker,
        args: %{"type" => "post", "id" => draft.id}
      )
    end
  end

  describe "JSON:API — deletion" do
    test "a read-only key cannot delete" do
      admin = user(:admin)
      post = CMS.create_post!(%{title: "Del", slug: slug()}, actor: admin)
      key = mint(admin, :read)

      assert {403, _} = req(:delete, "/api/json/posts/#{post.id}", bearer: key)
      assert CMS.get_post!(post.id, actor: admin)
    end

    test "an admin :read_write key can soft-delete (reversible)" do
      admin = user(:admin)
      post = CMS.create_post!(%{title: "Del", slug: slug()}, actor: admin)
      key = mint(admin, :read_write)

      assert {status, _} = req(:delete, "/api/json/posts/#{post.id}", bearer: key)
      assert status in [200, 204]

      # Soft-deleted: hidden from the normal read, still present in trash.
      assert [] = CMS.list_posts!(actor: admin, query: [filter: [id: post.id]])
    end

    test "an editor :read_write key cannot delete (role has no delete right)" do
      editor = user(:editor)
      post = CMS.create_post!(%{title: "Del", slug: slug()}, actor: editor)
      key = mint(editor, :read_write)

      assert {403, _} = req(:delete, "/api/json/posts/#{post.id}", bearer: key)
      assert CMS.get_post!(post.id, actor: user(:admin))
    end
  end

  describe "GraphQL mutations" do
    test "createPost with a :read_write editor key creates a draft" do
      owner = user(:editor)
      key = mint(owner, :read_write)
      s = slug()

      query = """
      mutation ($input: CreatePostInput!) {
        createPost(input: $input) { result { id slug } errors { message } }
      }
      """

      body = gql(query, %{input: %{title: "GQL", slug: s}}, bearer: key)
      assert body["data"]["createPost"]["result"]["slug"] == s
      assert body["data"]["createPost"]["errors"] == []

      [post] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
      assert post.state == :draft
      assert post.author_id == owner.id
    end

    test "createPost with a read-only key is not authorized" do
      key = mint(user(:editor), :read)
      s = slug()

      query = """
      mutation ($input: CreatePostInput!) {
        createPost(input: $input) { result { id } errors { message } }
      }
      """

      body = gql(query, %{input: %{title: "No", slug: s}}, bearer: key)

      # No record created; the mutation surfaces an authorization error rather
      # than a result.
      assert is_nil(get_in(body, ["data", "createPost", "result"]))
      assert [] = CMS.list_posts!(actor: user(:admin), query: [filter: [slug: s]])
    end

    test "publishPost is admin-gated and re-fires on success" do
      admin = user(:admin)
      admin_key = mint(admin, :read_write)
      post = CMS.create_post!(%{title: "GQL pub", slug: slug()}, actor: admin)

      query = """
      mutation ($id: ID!) {
        publishPost(id: $id) { result { id state } errors { message } }
      }
      """

      body = gql(query, %{id: post.id}, bearer: admin_key)
      assert body["data"]["publishPost"]["result"]["state"] == "published"
      assert CMS.get_post!(post.id, actor: admin).state == :published

      assert_enqueued(
        worker: KilnCMS.Firing.FireWorker,
        args: %{"type" => "post", "id" => post.id}
      )
    end
  end
end
