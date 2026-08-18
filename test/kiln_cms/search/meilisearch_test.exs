defmodule KilnCMS.Search.MeilisearchTest do
  @moduledoc """
  The optional Meilisearch backend (Project Plan Phase 6): publishing enqueues an
  upsert into the index and unpublishing enqueues a delete, both off the write
  path via `KilnCMS.Search.MeilisearchWorker`. Disabled by default, so the lean
  install enqueues nothing. Uses a stub HTTP client that records calls into the
  test process — no Meilisearch server required.
  """
  # async: false — toggles the global `KilnCMS.Search.Meilisearch` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search.Meilisearch

  # Records every request into the owning test process so assertions can inspect
  # what was sent. Always succeeds.
  defmodule StubClient do
    @behaviour KilnCMS.Search.Meilisearch.Client

    @impl true
    def request(method, path, body, _config) do
      pid = Application.get_env(:kiln_cms, :meili_test_pid)
      send(pid, {:meili, method, path, body})
      {:ok, %{"taskUid" => 1}}
    end
  end

  defp put_meili_env(overrides) do
    base = Application.get_env(:kiln_cms, Meilisearch, [])
    Application.put_env(:kiln_cms, Meilisearch, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, Meilisearch, [])
    Application.put_env(:kiln_cms, :meili_test_pid, self())

    on_exit(fn ->
      Application.put_env(:kiln_cms, Meilisearch, original)
      Application.delete_env(:kiln_cms, :meili_test_pid)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "meili-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "meili-#{System.unique_integer([:positive])}"

  defp drain, do: KilnCMS.DataCase.drain_oban()

  # Empty the stub's mailbox so a later assertion sees only what it triggered.
  defp flush do
    receive do
      {:meili, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  describe "config flag" do
    test "disabled by default" do
      refute Meilisearch.enabled?()
    end
  end

  describe "to_document/1" do
    test "builds a flat, prefixed document with a unix published_at" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Otters", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      doc = Meilisearch.to_document(page)

      assert doc.id == "page_#{page.id}"
      assert doc.type == "page"
      assert doc.title == "Otters"
      assert doc.slug == page.slug
      # The tenant facet (#336) — the page's org rides into the index document.
      assert doc.org_id == page.org_id
      assert is_integer(doc.published_at)
    end
  end

  describe "indexing on publish/unpublish (disabled)" do
    test "publishing enqueues no Meilisearch job when disabled" do
      actor = admin()

      CMS.create_page!(%{title: "Quiet", slug: slug(), blocks: []}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      refute_received {:meili, _method, _path, _body}
    end
  end

  describe "indexing on publish/unpublish (enabled)" do
    setup do
      put_meili_env(enabled: true, client: StubClient, index: "test_idx")
      :ok
    end

    test "publishing upserts the document into the index" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Indexed", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      assert %{success: success} = drain()
      assert success > 0

      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]}
      assert doc.id == "page_#{page.id}"
      assert doc.title == "Indexed"
    end

    test "a passphrase-locked document is deleted, not indexed (#496)" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Confidential", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [_doc]}

      page
      |> Ash.reload!(authorize?: false, tenant: page.org_id)
      |> CMS.update_page!(%{access_password: "shared secret"}, actor: actor)

      drain()

      # Meilisearch has no audience or grant facet and its queries are anonymous,
      # so anything indexed is readable by everyone. Locking previously-indexed
      # content therefore has to REMOVE it, not merely stop refreshing it.
      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> id, _body}
      assert id == page.id
      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
    end

    test "an audience-gated document is deleted, not indexed (#1006)" do
      # The index has no audience facet and its queries are anonymous, so an
      # indexed members-only body is anonymously searchable by anything holding
      # a search-only key. Gating previously-indexed content therefore has to
      # REMOVE it, not merely stop refreshing it.
      actor = admin()

      page =
        CMS.create_page!(%{title: "Members only", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [_doc]}

      page
      |> Ash.reload!(authorize?: false, tenant: page.org_id)
      |> CMS.update_page!(%{audience: :member}, actor: actor)

      drain()

      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> id, _body}
      assert id == page.id
      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
    end

    test "a document published straight into a gated audience is deleted, not indexed" do
      # The other order: gated BEFORE the first publish, so there is nothing in
      # the index to remove. It must still issue the DELETE rather than nothing
      # at all — that degradation IS the eviction mechanism the upgrade story
      # rests on, since `mix kiln.meili.reindex` enqueues an upsert for an
      # already-gated document and relies on it becoming a removal. A bare
      # `refute_received` on the PUT would stay green if it stopped.
      actor = admin()

      page =
        CMS.create_page!(%{title: "Born gated", slug: slug(), audience: :member, blocks: []},
          actor: actor
        )
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()

      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> id, _body}
      assert id == page.id
    end

    test "a gated POST is excluded too, not just a page" do
      # Every other test in this file uses a Page, so dropping the `published/1`
      # wrap from `load/3`'s "post" clause would survive all of them.
      actor = admin()

      post =
        CMS.create_post!(%{title: "Members only post", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_post!(&1, actor: actor))

      drain()
      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [_doc]}

      post
      |> Ash.reload!(authorize?: false, tenant: post.org_id)
      |> CMS.update_post!(%{audience: :member}, actor: actor)

      drain()

      assert_received {:meili, :delete, "/indexes/test_idx/documents/post_" <> id, _body}
      assert id == post.id
      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
    end

    test "index_document/1 refuses a gated record even when called directly" do
      # The worker is the only in-tree caller, but this is public API taking any
      # struct and `to_document/1` puts the whole denormalized body in `body`. A
      # console helper or a future bulk path must not be able to index a
      # members-only page silently.
      actor = admin()

      page =
        CMS.create_page!(%{title: "Direct", slug: slug(), audience: :member, blocks: []},
          actor: actor
        )
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      # Clear the publish-path DELETE so the refute below is about this call.
      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> _, _}

      assert :not_public =
               Meilisearch.index_document(
                 Ash.reload!(page, authorize?: false, tenant: page.org_id)
               )

      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
    end

    test "un-gating a document puts it back in the index" do
      # The rule is a property of the document's current audience, not a
      # one-way door: a page opened back up to everyone belongs in the index.
      actor = admin()

      page =
        CMS.create_page!(%{title: "Reopened", slug: slug(), audience: :member, blocks: []},
          actor: actor
        )
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}

      page
      |> Ash.reload!(authorize?: false, tenant: page.org_id)
      |> CMS.update_page!(%{audience: :public}, actor: actor)

      drain()

      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]}
      assert doc.title == "Reopened"
    end

    test "a dynamic-type entry is indexed, keyed by storage type and faceted by its own (#1012)" do
      # Every dynamic type fires under the `entry` storage key, and `load/3` had
      # clauses for page and post only — so publishing one issued a DELETE for a
      # document that had never been indexed, and the whole type was invisible
      # to the backend. Silently, which is what made it worth fixing.
      actor = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "mrecipe#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: actor
        )

      entry =
        ContentTypes.create!(definition.name, %{title: "Braised leeks", slug: slug()},
          actor: actor
        )

      {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)

      drain()

      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]}
      assert doc.title == "Braised leeks"

      # The primary key is the STORAGE type, because the delete path has only
      # `{type, id}` from the job args and must be able to compute the same key
      # for a record that may already be gone.
      assert doc.id == "entry_#{entry.id}"

      # The facet is the consumer-facing type — `type = "recipe"` is the whole
      # reason that attribute is filterable, and "entry" for every dynamic type
      # answers nothing.
      assert doc.type == definition.name
    end

    test "a gated dynamic entry is excluded like any other document" do
      # The #1006 rule is generic, but it had never actually run against an
      # entry, because entries never reached `published/1` at all.
      actor = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "mgated#{System.unique_integer([:positive])}", label: "Gated"},
          actor: actor
        )

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Members entry", slug: slug(), audience: :member},
          actor: actor
        )

      {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)

      drain()

      refute_received {:meili, :put, "/indexes/test_idx/documents" <> _, _}
      assert_received {:meili, :delete, "/indexes/test_idx/documents/entry_" <> id, _body}
      assert id == entry.id
    end

    test "unpublishing a dynamic entry deletes it under the STORAGE key" do
      # The delete path (`DeleteArtifacts.deindex/2`) computes its key from
      # `Engine.document_type/1`, so it must agree with `to_document/1`'s `id`.
      # The gated-entry test above does not exercise it — that routes through
      # `FireWorker` picking `"delete"` — so without this, switching `deindex/2`
      # to `public_type/1` (a natural-looking consistency fix) would issue
      # `DELETE .../recipe_<uuid>` and strand the real document forever.
      actor = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "munpub#{System.unique_integer([:positive])}", label: "Unpub"},
          actor: actor
        )

      entry =
        ContentTypes.create!(definition.name, %{title: "Temp entry", slug: slug()}, actor: actor)

      {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)
      drain()
      assert_received {:meili, :put, "/indexes/test_idx/documents" <> _, [_doc]}

      {:ok, _} = ContentTypes.transition(definition.name, "unpublish", entry, actor: actor)
      drain()

      assert_received {:meili, :delete, "/indexes/test_idx/documents/entry_" <> id, _body}
      assert id == entry.id
    end

    test "unpublishing deletes the document from the index" do
      actor = admin()

      page =
        CMS.create_page!(%{title: "Temp", slug: slug(), blocks: []}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      CMS.unpublish_page!(page, actor: actor)
      drain()

      assert_received {:meili, :delete, "/indexes/test_idx/documents/page_" <> rest, nil}
      assert rest == page.id
    end
  end

  describe "mix kiln.meili.reindex" do
    setup do
      put_meili_env(enabled: true, client: StubClient, index: "test_idx")
      :ok
    end

    test "enqueues every content tier, dynamic types included (#1012)" do
      # `Meilisearch.reindex_sources/0` is the backfill's whole notion of what
      # exists. Dropping a tier from it is silent — the task still reports
      # "enqueued N" — which is exactly how dynamic types went unindexed in the
      # first place.
      actor = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "mreidx#{System.unique_integer([:positive])}", label: "Reidx"},
          actor: actor
        )

      entry =
        ContentTypes.create!(definition.name, %{title: "Backfilled", slug: slug()}, actor: actor)

      {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)

      page =
        CMS.create_page!(%{title: "Backfilled page", slug: slug()}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      flush()

      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Kiln.Meili.Reindex.run([]) end)
      drain()

      indexed =
        Stream.repeatedly(fn ->
          receive do
            {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]} -> doc.id
            {:meili, _, _, _} -> :other
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert "entry_#{entry.id}" in indexed
      assert "page_#{page.id}" in indexed
    end
  end

  describe "reindex_all/0 — the release-callable backfill" do
    # The Mix task wraps this; a production release calls it over
    # `bin/kiln_cms rpc`, so its return contract is what an operator reads.
    defmodule FailingConfigureClient do
      @behaviour KilnCMS.Search.Meilisearch.Client

      @impl true
      def request(:patch, "/indexes/" <> _, _body, _config), do: {:error, :boom}
      def request(_method, _path, _body, _config), do: {:ok, %{}}
    end

    test "returns {:ok, count} of the published documents it enqueued" do
      put_meili_env(enabled: true, client: StubClient, index: "test_idx")
      actor = admin()

      page =
        CMS.create_page!(%{title: "Counted", slug: slug()}, actor: actor)
        |> then(&CMS.publish_page!(&1, actor: actor))

      # A draft is not published, so it must not be counted.
      CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

      drain()
      flush()

      assert {:ok, count} = Meilisearch.reindex_all()
      assert count >= 1

      # The settings PATCH ran before any document job was enqueued, and the
      # published page's upsert is among the drained jobs.
      assert_received {:meili, :patch, "/indexes/test_idx/settings", _}
      drain()

      indexed =
        Stream.repeatedly(fn ->
          receive do
            {:meili, :put, "/indexes/test_idx/documents" <> _, [doc]} -> doc.id
            {:meili, _, _, _} -> :other
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert "page_#{page.id}" in indexed
    end

    test "is :disabled, and enqueues nothing, when the backend is off" do
      put_meili_env(enabled: false, client: StubClient, index: "test_idx")
      actor = admin()

      CMS.create_page!(%{title: "Unseen", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      flush()

      assert :disabled = Meilisearch.reindex_all()
      refute_received {:meili, _, _, _}
    end

    test "propagates a configure error and enqueues nothing" do
      put_meili_env(enabled: true, client: FailingConfigureClient, index: "test_idx")
      actor = admin()

      CMS.create_page!(%{title: "Unseen", slug: slug()}, actor: actor)
      |> then(&CMS.publish_page!(&1, actor: actor))

      drain()
      flush()

      before = Oban.Job |> KilnCMS.Repo.all() |> length()
      assert {:error, :boom} = Meilisearch.reindex_all()
      assert Oban.Job |> KilnCMS.Repo.all() |> length() == before
    end
  end

  describe "search/2" do
    test "returns {:error, :disabled} when the backend is off" do
      assert {:error, :disabled} =
               Meilisearch.search("anything", org_id: KilnCMS.Accounts.default_org_id())
    end

    test "forces the tenant facet and returns hits when enabled" do
      put_meili_env(enabled: true, client: __MODULE__.SearchStub, index: "test_idx")
      org_id = "00000000-0000-0000-0000-0000000000aa"

      assert {:ok, [%{"title" => "Hit"}]} =
               Meilisearch.search("hit", org_id: org_id, type: :page, locale: "en")

      assert_received {:search_body, body}
      assert body.q == "hit"
      # `org_id` is a mandatory, quoted clause prepended to every query (#336).
      assert body.filter == ~s(org_id = "#{org_id}" AND type = page AND locale = "en")
    end

    test "requires an :org_id (tenant) — never spans orgs" do
      put_meili_env(enabled: true, client: __MODULE__.SearchStub, index: "test_idx")

      assert_raise ArgumentError, ~r/requires :org_id/, fn ->
        Meilisearch.search("hit", type: :page)
      end
    end
  end

  # Separate stub returning a hits payload for the search assertion.
  defmodule SearchStub do
    @behaviour KilnCMS.Search.Meilisearch.Client

    @impl true
    def request(:post, _path, body, _config) do
      send(Application.get_env(:kiln_cms, :meili_test_pid), {:search_body, body})
      {:ok, %{"hits" => [%{"title" => "Hit"}]}}
    end
  end
end
