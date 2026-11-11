defmodule KilnCMSWeb.DraftWriteKeyMediaAndPreviewTest do
  @moduledoc """
  The `:draft_write` API-key scope (#2273) on the surfaces that sit beside
  content: media writes (REST and GraphQL), preview-link minting, and version
  history. Each is driven with a real `kiln_` bearer key.

  The key's owner is promoted to `:editor` and `:admin` after minting in the
  cases that matter. Minting refuses such an owner, so that is the state a role
  change AFTER the mint creates — and the point of the scope is that it holds
  there too, because its forbid sits above the admin bypass.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @moduletag :capture_log

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-side-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "svc",
      DateTime.add(DateTime.utc_now(), 7, :day),
      %{access: :draft_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "dw-side-#{System.unique_integer([:positive])}"

  defp bearer(conn, key), do: put_req_header(conn, "authorization", "Bearer #{key}")

  defp promote(owner, role), do: Ash.Seed.update!(owner, %{role: role})

  defp upload(bytes, filename) do
    path = Path.join(System.tmp_dir!(), "dw-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: "image/png"}
  end

  defp media_names(admin) do
    CMS.list_media_items!(actor: admin) |> MapSet.new(& &1.filename)
  end

  setup do
    owner = user(:viewer)
    %{owner: owner, key: mint(owner), admin: user(:admin)}
  end

  # Both tiers: the as-minted viewer owner, and the owner promoted afterwards.
  defp owners(ctx) do
    [{:viewer, ctx.key}, {:editor, ctx.key}, {:admin, ctx.key}]
    |> Enum.map(fn {role, key} ->
      if role != :viewer, do: promote(ctx.owner, role)
      {role, key}
    end)
  end

  describe "media writes" do
    test "POST /api/media is refused whatever the owner's role", ctx do
      for {role, key} <- owners(ctx) do
        name = "dw-#{role}-#{System.unique_integer([:positive])}.png"

        conn =
          build_conn()
          |> bearer(key)
          |> post("/api/media", %{"file" => upload(@png, name)})

        assert json_response(conn, 403)["errors"] |> hd() |> Map.fetch!("code") == "forbidden",
               "owner #{role}"

        refute name in media_names(ctx.admin)
      end
    end

    test "import-url and direct-upload begin are refused", ctx do
      promote(ctx.owner, :admin)

      conn =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/media/import-url", Jason.encode!(%{url: "https://media.test/a.png"}))

      assert json_response(conn, 403)["errors"] |> hd() |> Map.fetch!("code") == "forbidden"

      conn =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/media/uploads", Jason.encode!(%{filename: "a.mp4", byte_size: 10}))

      assert conn.status in [403, 501]
      assert conn.status == 403
    end

    test "metadata edits on an existing item are refused on JSON:API and GraphQL", ctx do
      promote(ctx.owner, :admin)

      item =
        Ash.Seed.seed!(CMS.MediaItem, %{
          filename: "seed-#{slug()}.png",
          content_type: "image/png",
          kind: :image,
          size: 1,
          storage_key: "k-#{slug()}",
          alt: "original"
        })

      conn =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch(
          "/api/json/media-items/#{item.id}",
          Jason.encode!(%{
            data: %{type: "media_item", id: item.id, attributes: %{alt: "hijack"}}
          })
        )

      assert conn.status in [403, 404]

      query = """
      mutation ($id: ID!, $input: UpdateMediaItemInput) {
        updateMediaItem(id: $id, input: $input) { result { id } errors { message } }
      }
      """

      body =
        build_conn()
        |> bearer(ctx.key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/gql",
          Jason.encode!(%{query: query, variables: %{id: item.id, input: %{alt: "hijack"}}})
        )
        |> json_response(200)

      assert is_nil(get_in(body, ["data", "updateMediaItem", "result"]))
      assert CMS.get_media_item!(item.id, actor: ctx.admin).alt == "original"
    end
  end

  describe "preview-link minting" do
    defp mint_preview(key, type, id) do
      build_conn()
      |> bearer(key)
      |> post("/api/content/#{type}/#{id}/preview-token")
    end

    test "a viewer-tier owner (the normal case) mints nothing, not even for its own draft", ctx do
      own =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Mine",
          slug: slug(),
          state: :draft,
          author_id: ctx.owner.id
        })

      assert mint_preview(ctx.key, "post", own.id).status in [403, 404]
    end

    test "an owner promoted after minting still mints only for drafts the key's owner authored",
         ctx do
      promote(ctx.owner, :editor)

      own =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Mine",
          slug: slug(),
          state: :draft,
          author_id: ctx.owner.id
        })

      theirs =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Theirs",
          slug: slug(),
          state: :draft,
          author_id: user(:editor).id
        })

      live =
        Ash.Seed.seed!(CMS.Post, %{
          title: "Live",
          slug: slug(),
          state: :published,
          author_id: ctx.owner.id
        })

      assert %{"token" => _} = json_response(mint_preview(ctx.key, "post", own.id), 201)

      assert json_response(mint_preview(ctx.key, "post", theirs.id), 403)["errors"]
             |> hd()
             |> Map.fetch!("code") == "forbidden"

      assert mint_preview(ctx.key, "post", live.id).status in [403, 404]
    end

    test "an ordinary editor key is unaffected (mints for any draft it can see)", ctx do
      editor = user(:editor)

      key =
        editor.id
        |> Accounts.mint_api_key!(
          "rw",
          DateTime.add(DateTime.utc_now(), 7, :day),
          %{access: :read_write},
          actor: ctx.admin
        )
        |> Ash.Resource.get_metadata(:plaintext_api_key)

      theirs =
        Ash.Seed.seed!(CMS.Post, %{
          title: "T",
          slug: slug(),
          state: :draft,
          author_id: user(:editor).id
        })

      assert json_response(mint_preview(key, "post", theirs.id), 201)["token"]
    end
  end

  describe "version history" do
    test "a viewer-tier owner reads no revisions, not even of its own draft", ctx do
      assert {201, id} = create_own_draft(ctx.key)

      conn = build_conn() |> bearer(ctx.key) |> get("/api/content/post/#{id}/revisions")
      assert conn.status in [403, 404]
    end

    test "restore is refused even once the owner is promoted (reads follow the owner's role)",
         ctx do
      assert {201, id} = create_own_draft(ctx.key)
      promote(ctx.owner, :admin)

      post = CMS.get_post!(id, actor: ctx.admin)

      [version | _] =
        CMS.list_post_versions!(actor: ctx.admin)
        |> Enum.filter(&(&1.version_source_id == post.id))

      conn =
        build_conn()
        |> bearer(ctx.key)
        |> post("/api/content/post/#{id}/revisions/#{version.id}/restore")

      assert conn.status in [403, 404]
      assert CMS.get_post!(id, actor: ctx.admin).updated_at == post.updated_at
    end

    defp create_own_draft(key) do
      conn =
        build_conn()
        |> bearer(key)
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(
          "/api/json/posts",
          Jason.encode!(%{data: %{type: "post", attributes: %{title: "T", slug: slug()}}})
        )

      {conn.status, Jason.decode!(conn.resp_body)["data"]["id"]}
    end
  end
end
