defmodule KilnCMS.Search.BlockSearchTest do
  @moduledoc "Phase I — block-granular embeddings + faceted semantic search (D16)."
  # async: false — toggles the global KilnCMS.Search app env (stub embedder).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.{CMS, SearchIndex}
  alias KilnCMS.Search.{BlockIndexer, BlockSearch}

  # Deterministic stub: same text → same 384-d vector, no model loaded.
  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: StubEmbedder)
    )

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bsrch-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "bsrch-#{System.unique_integer([:positive])}"

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp page_with_blocks(actor, blocks),
    do: CMS.create_page!(%{title: "Doc", slug: slug(), blocks: blocks}, actor: actor)

  defp page_with_blocks(actor, org, blocks),
    do: CMS.create_page!(%{title: "Doc", slug: slug(), blocks: blocks}, actor: actor, tenant: org)

  describe "BlockIndexer.reindex/1" do
    test "embeds one row per non-empty block, keyed by block, deduped by hash" do
      actor = admin()

      page =
        page_with_blocks(actor, [
          %{type: :heading, content: "Otters", order: 0},
          %{type: :rich_text, content: "<p>rivers and streams</p>", order: 1},
          %{type: :divider, order: 2}
        ])

      {:ok, count} = BlockIndexer.reindex(page)
      # heading + rich_text embed; divider has no search text.
      assert count == 2

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.document_type == :page))

      # Re-indexing unchanged content embeds nothing new.
      assert {:ok, 0} = BlockIndexer.reindex(page)
    end
  end

  describe "BlockSearch.search/2" do
    test "returns the nearest block and supports block_type faceting" do
      actor = admin()

      page =
        page_with_blocks(actor, [
          %{type: :heading, content: "Mountains", order: 0},
          %{type: :quote, content: "Mountains are calling", order: 1}
        ])

      {:ok, 2} = BlockIndexer.reindex(page)

      results = BlockSearch.search("Mountains")
      assert length(results) == 2

      # Facet to just headings.
      headings = BlockSearch.search("Mountains", block_type: :heading)
      assert Enum.all?(headings, &(&1.block_type == :heading))
      assert length(headings) == 1
    end

    test "is tenant-scoped — a search sees only its own org's blocks (#336)" do
      actor = admin()
      a = org("orga")
      b = org("orgb")

      # The SAME block text indexed under two different orgs.
      pa = page_with_blocks(actor, a, [%{type: :heading, content: "Shared Term", order: 0}])
      pb = page_with_blocks(actor, b, [%{type: :heading, content: "Shared Term", order: 0}])
      {:ok, 1} = BlockIndexer.reindex(pa)
      {:ok, 1} = BlockIndexer.reindex(pb)

      a_results = BlockSearch.search("Shared Term", org_id: a.id)
      assert Enum.all?(a_results, &(&1.document_id == pa.id))
      refute Enum.any?(a_results, &(&1.document_id == pb.id))

      b_results = BlockSearch.search("Shared Term", org_id: b.id)
      assert Enum.all?(b_results, &(&1.document_id == pb.id))
      refute Enum.any?(b_results, &(&1.document_id == pa.id))
    end

    test "returns nothing when semantic search is disabled" do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Search), semantic: false)
      )

      assert BlockSearch.search("anything") == []
    end
  end

  describe "embed-on-fire" do
    test "publishing a page enqueues block indexing" do
      actor = admin()
      page = page_with_blocks(actor, [%{type: :heading, content: "Indexed on publish", order: 0}])
      CMS.publish_page!(page, actor: actor)

      assert %{success: success} = KilnCMS.DataCase.drain_oban()
      assert success >= 1

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert length(rows) == 1
    end
  end
end
