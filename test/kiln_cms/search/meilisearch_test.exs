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
