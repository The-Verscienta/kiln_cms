defmodule KilnCMSWeb.SyncControllerTest do
  @moduledoc """
  `GET /api/sync` — the delta API (`KilnCMS.Firing.Sync`).

  Most of what is asserted here is about what an anonymous caller must NOT
  learn: a document that stops being public arrives as a bare tombstone, and a
  document that was never public never appears at all — not even as an id.
  """
  # async: false — the commit lag is app config, and delivery reads through the
  # shared content cache and dynamic-type registry.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.CMS.ContentTypes

  @gated hd(Audiences.gated())

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Firing.Sync)
    # The lag guards against in-flight transactions in production; here every
    # write has committed (to the sandbox) before the next request, and a test
    # cannot wait ten seconds per delta.
    Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, previous),
        else: Application.delete_env(:kiln_cms, KilnCMS.Firing.Sync)
    end)

    KilnCMS.Cache.bust_published()
    org = seed_org()
    %{org: org, admin: admin()}
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Sync Site",
      slug: "sync-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "sync-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp post!(ctx, attrs \\ %{}) do
    CMS.create_post!(
      Map.merge(
        %{
          title: "Post #{System.unique_integer([:positive])}",
          slug: "sync-post-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "heading", "text" => "The body text", "level" => 2}]
        },
        attrs
      ),
      actor: ctx.admin,
      tenant: ctx.org
    )
  end

  defp published_post!(ctx, attrs \\ %{}),
    do: ctx |> post!(attrs) |> CMS.publish_post!(%{}, actor: ctx.admin, tenant: ctx.org)

  defp page!(ctx) do
    page =
      CMS.create_page!(
        %{title: "A page", slug: "sync-page-#{System.unique_integer([:positive])}"},
        actor: ctx.admin,
        tenant: ctx.org
      )

    CMS.publish_page!(page, %{}, actor: ctx.admin, tenant: ctx.org)
  end

  # Publishing fires artifacts in a background job; run it first, as the
  # production queue would have by the time a poll arrives. The 503 path, where
  # it hasn't, is tested on its own below.
  defp sync(conn, ctx, params, drain? \\ true) do
    if drain?, do: KilnCMS.DataCase.drain_oban()

    conn
    |> org_conn(ctx.org)
    |> get("/api/sync", params)
  end

  defp sync!(conn, ctx, params), do: conn |> sync(ctx, params) |> json_response(200)

  # Every page from `params` to the end — the items, and the cursor to store.
  defp drain(conn, ctx, params, acc \\ []) do
    body = sync!(conn, ctx, params)
    acc = acc ++ body["items"]

    if body["has_more"],
      do: drain(conn, ctx, %{"cursor" => body["cursor"]}, acc),
      else: {acc, body["cursor"]}
  end

  defp ids(items, op), do: for(%{"op" => ^op, "id" => id} <- items, do: id)

  describe "initial sync" do
    test "returns exactly what an anonymous reader may read, with its artifact",
         %{conn: conn} = ctx do
      public = published_post!(ctx)
      _draft = post!(ctx)
      _gated = published_post!(ctx, %{audience: @gated})
      _locked = published_post!(ctx, %{access_password: "shared secret"})

      {items, cursor} = drain(conn, ctx, %{"initial" => "true", "type" => "post"})

      assert [item] = items
      assert item["op"] == "upsert"
      assert item["id"] == public.id
      assert item["type"] == "post"
      assert item["slug"] == public.slug
      assert item["locale"] == public.locale
      # The same fired body `GET /api/content/post/:slug` serves.
      assert item["artifact"]["slug"] == public.slug
      assert is_binary(cursor)
    end

    test "pages through every type once, keyset across tables", %{conn: conn} = ctx do
      posts = for _ <- 1..3, do: published_post!(ctx)
      page = page!(ctx)

      {items, _cursor} = drain(conn, ctx, %{"initial" => "true", "limit" => "1"})

      expected = Enum.sort([page.id | Enum.map(posts, & &1.id)])
      assert Enum.sort(ids(items, "upsert")) == expected
      assert length(items) == length(expected)
    end

    test "a credential does not widen it — drafts stay out for an admin key",
         %{conn: conn} = ctx do
      _draft = post!(ctx)

      key =
        Accounts.mint_api_key!(ctx.admin.id, "sync", DateTime.add(DateTime.utc_now(), 1, :day),
          actor: ctx.admin
        )

      plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)

      body =
        conn
        |> put_req_header("authorization", "Bearer #{plaintext}")
        |> sync!(ctx, %{"initial" => "true"})

      assert body["items"] == []
    end

    test "never cached", %{conn: conn} = ctx do
      conn = sync(conn, ctx, %{"initial" => "true"})
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "delta" do
    test "reports a new publish as an upsert and nothing unchanged", %{conn: conn} = ctx do
      _before = published_post!(ctx)
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

      added = published_post!(ctx)
      {items, next} = drain(conn, ctx, %{"cursor" => cursor})

      assert ids(items, "upsert") == [added.id]
      assert ids(items, "delete") == []

      # And the next poll, with nothing changed, is empty.
      assert {[], _} = drain(conn, ctx, %{"cursor" => next})
    end

    test "an edit to a published document re-sends it", %{conn: conn} = ctx do
      post = published_post!(ctx)
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

      post
      |> CMS.unpublish_post!(%{}, actor: ctx.admin, tenant: ctx.org)
      |> CMS.update_post!(%{title: "Retitled"}, actor: ctx.admin, tenant: ctx.org)
      |> CMS.publish_post!(%{}, actor: ctx.admin, tenant: ctx.org)

      {items, _} = drain(conn, ctx, %{"cursor" => cursor})
      assert [%{"op" => "upsert", "id" => id, "artifact" => artifact}] = items
      assert id == post.id
      assert artifact["title"] == "Retitled"
    end

    for {label, take_down} <- [
          unpublish: &__MODULE__.unpublish/2,
          archive: &__MODULE__.archive/2,
          soft_delete: &__MODULE__.soft_delete/2,
          purge: &__MODULE__.purge/2,
          members_only: &__MODULE__.gate/2,
          passphrase_lock: &__MODULE__.lock/2
        ] do
      test "#{label} of a synced document is a bare tombstone", %{conn: conn} = ctx do
        post = published_post!(ctx)
        {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

        unquote(take_down).(post, ctx)

        {items, _} = drain(conn, ctx, %{"cursor" => cursor})

        # Id and type — never a body, a slug, or why.
        assert items == [%{"op" => "delete", "type" => "post", "id" => post.id}]
      end
    end

    test "a document that was never public never appears — not even as an id",
         %{conn: conn} = ctx do
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

      # Published to members from the start, then edited and taken down; a
      # draft edited and deleted; a locked document edited. All changed inside
      # the window, none ever visible to an anonymous reader.
      gated = published_post!(ctx, %{audience: @gated})
      CMS.update_post!(gated, %{title: "Still gated"}, actor: ctx.admin, tenant: ctx.org)

      draft = post!(ctx)
      draft = CMS.update_post!(draft, %{title: "Draft 2"}, actor: ctx.admin, tenant: ctx.org)
      CMS.destroy_post!(draft, actor: ctx.admin, tenant: ctx.org)

      locked = published_post!(ctx, %{access_password: "shared secret"})
      CMS.update_post!(locked, %{title: "Locked 2"}, actor: ctx.admin, tenant: ctx.org)

      assert {[], _} = drain(conn, ctx, %{"cursor" => cursor})
    end

    test "a document that came back is an upsert again", %{conn: conn} = ctx do
      post = published_post!(ctx)
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

      post = unpublish(post, ctx)
      {[%{"op" => "delete"}], cursor} = drain(conn, ctx, %{"cursor" => cursor})

      CMS.publish_post!(post, %{}, actor: ctx.admin, tenant: ctx.org)
      assert {[%{"op" => "upsert", "id" => id}], _} = drain(conn, ctx, %{"cursor" => cursor})
      assert id == post.id
    end

    test "pages a large delta without losing or repeating a document", %{conn: conn} = ctx do
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})
      added = for _ <- 1..5, do: published_post!(ctx)

      {items, _} = drain(conn, ctx, %{"cursor" => cursor, "limit" => "2"})
      assert Enum.sort(ids(items, "upsert")) == Enum.sort(Enum.map(added, & &1.id))
    end

    test "a type-scoped cursor stays scoped", %{conn: conn} = ctx do
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true", "type" => "post"})

      _page = page!(ctx)
      post = published_post!(ctx)

      # `type` on a cursor request is ignored — the cursor carries its scope.
      {items, _} = drain(conn, ctx, %{"cursor" => cursor, "type" => "page"})
      assert ids(items, "upsert") == [post.id]
    end

    test "the commit lag holds back changes too fresh to be settled", ctx do
      {:ok, _items, cursor, false} =
        KilnCMS.Firing.Sync.page(ctx.org.id, nil, KilnCMS.Firing.Sync.start(), commit_lag: 0)

      post = published_post!(ctx)
      KilnCMS.DataCase.drain_oban()

      # Inside the lag: nothing yet, and the cursor does not advance past it.
      assert {:ok, [], ^cursor, false} =
               KilnCMS.Firing.Sync.page(ctx.org.id, nil, cursor, commit_lag: 60)

      later = DateTime.add(DateTime.utc_now(), 61, :second)

      assert {:ok, [%{op: "upsert", id: id}], _, false} =
               KilnCMS.Firing.Sync.page(ctx.org.id, nil, cursor, commit_lag: 60, now: later)

      assert id == post.id
    end
  end

  describe "dynamic types" do
    setup ctx do
      definition =
        CMS.create_type_definition!(
          %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: ctx.admin,
          tenant: ctx.org
        )

      %{definition: definition}
    end

    defp entry!(ctx) do
      entry =
        ContentTypes.create!(
          ctx.definition.name,
          %{title: "Pancakes", slug: "pancakes-#{System.unique_integer([:positive])}"},
          actor: ctx.admin,
          tenant: ctx.org
        )

      {:ok, entry} =
        ContentTypes.transition(ctx.definition.name, "publish", entry,
          actor: ctx.admin,
          tenant: ctx.org
        )

      entry
    end

    test "a dynamic type syncs under its own name", %{conn: conn} = ctx do
      entry = entry!(ctx)

      {items, _} = drain(conn, ctx, %{"initial" => "true", "type" => ctx.definition.name})
      assert [%{"op" => "upsert", "type" => type, "id" => id}] = items
      assert type == ctx.definition.name
      assert id == entry.id
    end

    test "a purged entry is tombstoned under its type, scoped by what was disclosed",
         %{conn: conn} = ctx do
      entry = entry!(ctx)
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true", "type" => ctx.definition.name})

      CMS.purge_entry!(entry, actor: ctx.admin, tenant: ctx.org)

      {items, _} = drain(conn, ctx, %{"cursor" => cursor})
      assert items == [%{"op" => "delete", "type" => ctx.definition.name, "id" => entry.id}]
    end
  end

  describe "a document without its artifact yet" do
    test "answers 503 for the page, then serves it once fired", %{conn: conn} = ctx do
      post = published_post!(ctx)

      conn_503 = sync(conn, ctx, %{"initial" => "true"}, false)
      assert %{"errors" => [%{"code" => "artifact_compiling"}]} = json_response(conn_503, 503)
      assert get_resp_header(conn_503, "retry-after") == ["2"]

      assert {[%{"op" => "upsert", "id" => id}], _} = drain(conn, ctx, %{"initial" => "true"})
      assert id == post.id
    end
  end

  describe "requests it refuses" do
    test "neither or both of initial and cursor", %{conn: conn} = ctx do
      assert %{"errors" => [%{"code" => "missing_cursor"}]} =
               conn |> sync(ctx, %{}) |> json_response(400)

      assert %{"errors" => [%{"code" => "invalid_request"}]} =
               conn |> sync(ctx, %{"initial" => "true", "cursor" => "x"}) |> json_response(400)
    end

    test "a tampered cursor", %{conn: conn} = ctx do
      body = sync!(conn, ctx, %{"initial" => "true"})

      assert %{"errors" => [%{"code" => "invalid_cursor"}]} =
               conn |> sync(ctx, %{"cursor" => body["cursor"] <> "x"}) |> json_response(400)
    end

    test "another site's cursor", %{conn: conn} = ctx do
      published_post!(ctx)
      %{"cursor" => cursor} = sync!(conn, ctx, %{"initial" => "true"})

      other = %{ctx | org: seed_org()}

      assert %{"errors" => [%{"code" => "invalid_cursor"}]} =
               conn |> sync(other, %{"cursor" => cursor}) |> json_response(400)
    end

    test "an unknown type or surface", %{conn: conn} = ctx do
      assert conn |> sync(ctx, %{"initial" => "true", "type" => "nope"}) |> json_response(404)

      assert %{"errors" => [%{"code" => "invalid_surface"}]} =
               conn |> sync(ctx, %{"initial" => "true", "surface" => "pdf"}) |> json_response(400)
    end
  end

  # ── Take-down verbs (public so the generated tests can capture them) ──────

  @doc false
  def unpublish(post, ctx), do: CMS.unpublish_post!(post, %{}, actor: ctx.admin, tenant: ctx.org)

  @doc false
  def archive(post, ctx), do: CMS.archive_post!(post, %{}, actor: ctx.admin, tenant: ctx.org)

  @doc false
  def soft_delete(post, ctx), do: CMS.destroy_post!(post, actor: ctx.admin, tenant: ctx.org)

  @doc false
  def purge(post, ctx), do: CMS.purge_post!(post, actor: ctx.admin, tenant: ctx.org)

  @doc false
  def gate(post, ctx),
    do: CMS.update_post!(post, %{audience: @gated}, actor: ctx.admin, tenant: ctx.org)

  @doc false
  def lock(post, ctx),
    do:
      CMS.update_post!(post, %{access_password: "shared secret"},
        actor: ctx.admin,
        tenant: ctx.org
      )
end
