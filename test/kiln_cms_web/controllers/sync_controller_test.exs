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

  import Ecto.Query, only: [from: 2]

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

  # #1713: a page's artifacts come from the cache already encoded, and an
  # exposure already recorded is not written again. Neither may change a byte
  # of what a page says, or what a later delta may name.
  describe "initial page served from the encoded cache" do
    test "is byte for byte what encoding the stored artifacts gives, cold and warm",
         %{conn: conn} = ctx do
      posts = for _ <- 1..3, do: published_post!(ctx)
      page = page!(ctx)
      KilnCMS.DataCase.drain_oban()

      KilnCMS.Firing.Cache.clear()
      cold = conn |> sync(ctx, %{"initial" => "true"}) |> response(200)
      warm = conn |> sync(ctx, %{"initial" => "true"}) |> response(200)

      # The cursor carries the instant the snapshot began, so it differs by
      # request; everything around it must not.
      assert without_cursor(cold) == without_cursor(warm)

      # Rebuilt by hand from the database: the documents' own columns and the
      # artifact rows, encoded the way the controller always encoded them.
      %{"cursor" => cursor} = Jason.decode!(warm)

      # Scopes walk in resource-name order (Page before Post), each by id;
      # re-read so the timestamps are the ones the database holds now.
      docs =
        [CMS.get_page!(page.id, actor: ctx.admin, tenant: ctx.org)] ++
          (posts
           |> Enum.sort_by(& &1.id)
           |> Enum.map(&CMS.get_post!(&1.id, actor: ctx.admin, tenant: ctx.org)))

      golden =
        Jason.encode!(%{
          items:
            Enum.map(docs, fn doc ->
              type = KilnCMS.Firing.Engine.document_type(doc)

              %{
                op: "upsert",
                type: to_string(type),
                id: doc.id,
                slug: doc.slug,
                locale: doc.locale,
                published_at: doc.published_at,
                updated_at: doc.updated_at,
                artifact: stored_body(ctx, type, doc.id)
              }
            end),
          cursor: cursor,
          has_more: false
        })

      assert warm == golden
    end

    test "reads what the cache lacks in one query per type, not one per document",
         %{conn: conn} = ctx do
      for _ <- 1..4, do: published_post!(ctx)
      page!(ctx)
      KilnCMS.DataCase.drain_oban()
      KilnCMS.Firing.Cache.clear()

      # A page and the posts: two types, two queries.
      assert {5, 2} =
               artifact_queries(fn ->
                 {items, _} = drain(conn, ctx, %{"initial" => "true"})
                 length(items)
               end)

      # Warm, none.
      assert {5, 0} =
               artifact_queries(fn ->
                 {items, _} = drain(conn, ctx, %{"initial" => "true"})
                 length(items)
               end)
    end

    test "a republished document is served with its new artifact", %{conn: conn} = ctx do
      post = published_post!(ctx)
      {[first], _} = drain(conn, ctx, %{"initial" => "true"})
      assert first["artifact"]["title"] == post.title

      post
      |> CMS.unpublish_post!(%{}, actor: ctx.admin, tenant: ctx.org)
      |> CMS.update_post!(%{title: "Retitled"}, actor: ctx.admin, tenant: ctx.org)
      |> CMS.publish_post!(%{}, actor: ctx.admin, tenant: ctx.org)

      {[again], _} = drain(conn, ctx, %{"initial" => "true"})
      assert again["artifact"]["title"] == "Retitled"

      assert again["artifact"] ==
               ctx |> stored_body(:post, post.id) |> Jason.encode!() |> Jason.decode!()
    end

    test "an unpublished document leaves the initial page", %{conn: conn} = ctx do
      kept = published_post!(ctx)
      gone = published_post!(ctx)
      {items, _} = drain(conn, ctx, %{"initial" => "true"})
      assert Enum.sort(ids(items, "upsert")) == Enum.sort([kept.id, gone.id])

      unpublish(gone, ctx)

      assert {[%{"id" => id}], _} = drain(conn, ctx, %{"initial" => "true"})
      assert id == kept.id
    end

    test "another site's warm cache does not reach this site's page", %{conn: conn} = ctx do
      mine = published_post!(ctx)
      {[_], _} = drain(conn, ctx, %{"initial" => "true"})

      other = %{ctx | org: seed_org()}
      theirs = published_post!(other)

      assert {[%{"id" => id}], _} = drain(conn, other, %{"initial" => "true"})
      assert id == theirs.id

      mine_id = mine.id
      assert {[%{"id" => ^mine_id}], _} = drain(conn, ctx, %{"initial" => "true"})
    end
  end

  describe "exposures on a page served again" do
    test "are written once, and the type name is kept current", %{conn: conn} = ctx do
      post = published_post!(ctx)
      {[_], _} = drain(conn, ctx, %{"initial" => "true"})
      [recorded] = exposure_rows(post.id)

      # Served again: the row is left alone, not rewritten. An upsert that
      # changed nothing would still write a new tuple, and move its `ctid`.
      {[_], _} = drain(conn, ctx, %{"initial" => "true"})
      assert exposure_rows(post.id) == [recorded]

      # Recorded under another name (as after a dynamic type's rename): the
      # next page that serves the document writes the current one.
      KilnCMS.Repo.update_all(
        from(e in "sync_exposures", where: e.document_id == type(^post.id, Ecto.UUID)),
        set: [type_name: "renamed"]
      )

      {[_], _} = drain(conn, ctx, %{"initial" => "true"})
      assert [%{type_name: "post"}] = exposure_rows(post.id)
    end

    test "a document first served on a later page can still be tombstoned",
         %{conn: conn} = ctx do
      first = published_post!(ctx)
      {_, cursor} = drain(conn, ctx, %{"initial" => "true"})
      second = published_post!(ctx)
      {_, cursor} = drain(conn, ctx, %{"cursor" => cursor})

      # Both served, so both may be named when they go.
      unpublish(first, ctx)
      unpublish(second, ctx)

      {items, _} = drain(conn, ctx, %{"cursor" => cursor})
      assert Enum.sort(ids(items, "delete")) == Enum.sort([first.id, second.id])
    end
  end

  # `fun`'s result, and how many queries it made of the artifact table.
  defp artifact_queries(fun) do
    test_pid = self()
    handler = "sync-artifact-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and meta[:source] == "published_artifacts",
          do: send(test_pid, :artifact_query)
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, count_messages(:artifact_query, 0)}
  end

  defp count_messages(message, count) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end

  defp without_cursor(body), do: body |> Jason.decode!() |> Map.delete("cursor")

  defp stored_body(ctx, type, id) do
    {:ok, artifact} =
      KilnCMS.Firing.get_artifact(type, id, :json,
        actor: KilnCMS.SystemActor.new(:delivery),
        tenant: ctx.org.id
      )

    artifact.body
  end

  defp exposure_rows(document_id) do
    KilnCMS.Repo.all(
      from(e in "sync_exposures",
        where: e.document_id == type(^document_id, Ecto.UUID),
        select: %{
          id: e.id,
          type_name: e.type_name,
          tuple: fragment("ctid::text")
        }
      )
    )
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

    # #1621: a page halted at its first miss and queued that one document, so
    # k never-fired documents took k 503 -> retry rounds, more than a client's
    # retries allow.
    test "one request queues every never-fired document on the page, across types",
         %{conn: conn} = ctx do
      published = [page!(ctx) | for(_ <- 1..4, do: published_post!(ctx))]
      forget_fires()

      conn_503 = sync(conn, ctx, %{"initial" => "true"}, false)
      assert %{"errors" => [%{"code" => "artifact_compiling"}]} = json_response(conn_503, 503)
      assert get_resp_header(conn_503, "retry-after") == ["2"]
      assert Enum.sort(queued_fires()) == Enum.sort(Enum.map(published, & &1.id))

      # A retry before they have run queues nothing twice.
      assert conn |> sync(ctx, %{"initial" => "true"}, false) |> json_response(503)
      assert length(queued_fires()) == length(published)

      # One retry after they have run serves the whole page.
      {items, _cursor} = drain(conn, ctx, %{"initial" => "true"})
      assert Enum.sort(ids(items, "upsert")) == Enum.sort(Enum.map(published, & &1.id))
    end

    test "a delta page queues every never-fired document too", %{conn: conn} = ctx do
      {_items, cursor} = drain(conn, ctx, %{"initial" => "true"})

      published = [page!(ctx) | for(_ <- 1..3, do: published_post!(ctx))]
      forget_fires()

      assert conn |> sync(ctx, %{"cursor" => cursor}, false) |> json_response(503)
      assert Enum.sort(queued_fires()) == Enum.sort(Enum.map(published, & &1.id))

      {items, _} = drain(conn, ctx, %{"cursor" => cursor})
      assert Enum.sort(ids(items, "upsert")) == Enum.sort(Enum.map(published, & &1.id))
    end

    test "the cursor never moves past a document it did not serve", %{conn: conn} = ctx do
      fired = for _ <- 1..3, do: published_post!(ctx)
      KilnCMS.DataCase.drain_oban()
      unfired = for _ <- 1..4, do: published_post!(ctx)
      forget_fires()

      {items, rounds_503} = walk(conn, ctx, %{"initial" => "true", "limit" => "2"})

      assert rounds_503 > 0
      all = Enum.map(fired ++ unfired, & &1.id)
      # Every document exactly once: none skipped, none repeated.
      assert Enum.sort(ids(items, "upsert")) == Enum.sort(all)
    end
  end

  # A client that keeps its cursor: on a 503 it lets the queue run and retries
  # the same page. Returns every item and how many 503s it took.
  defp walk(conn, ctx, params, acc \\ {[], 0}) do
    {items, rounds} = acc
    response = sync(conn, ctx, params, false)

    case response.status do
      503 ->
        KilnCMS.DataCase.drain_oban()
        walk(conn, ctx, params, {items, rounds + 1})

      200 ->
        body = json_response(response, 200)
        acc = {items ++ body["items"], rounds}

        if body["has_more"],
          do: walk(conn, ctx, %{"cursor" => body["cursor"], "limit" => params["limit"]}, acc),
          else: acc
    end
  end

  # Documents published before firing existed, or whose fire was lost: no
  # artifact and no job coming.
  defp forget_fires do
    KilnCMS.Repo.delete_all(from(j in Oban.Job, where: j.worker == "KilnCMS.Firing.FireWorker"))
  end

  defp queued_fires do
    KilnCMS.Repo.all(
      from(j in Oban.Job,
        where: j.worker == "KilnCMS.Firing.FireWorker" and j.state == "available",
        select: fragment("?->>'id'", j.args)
      )
    )
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
