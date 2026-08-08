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

  # An embedder that is down — the serving not started, or out of memory.
  defmodule BrokenEmbedder do
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: {:error, :unavailable}
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

    test "a deleted block's row is deleted too (#965)" do
      # `upsert` was the only write, so the index only ever grew. A stored
      # centroid averages EVERY row for the document, so a trimmed page kept
      # being described by text it no longer contains.
      actor = admin()

      page =
        page_with_blocks(actor, [
          %{type: :heading, content: "Otters", order: 0},
          %{type: :rich_text, content: "<p>rivers and streams</p>", order: 1}
        ])

      {:ok, 2} = BlockIndexer.reindex(page)

      trimmed =
        CMS.update_page!(
          page,
          %{blocks: [%{type: :heading, content: "Otters", order: 0}]},
          actor: actor
        )

      {:ok, _} = BlockIndexer.reindex(trimmed)

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert length(rows) == 1
      assert [%{block_type: :heading}] = rows
    end

    test "a block that stays but loses its text has its row deleted (#965)" do
      # Distinct from the case above: the block is STILL IN THE TREE, under the
      # same id, and only its text is gone. `index_block/7` answers `:skip` for
      # it, which used to leave the previous row describing a paragraph the
      # author had cleared.
      actor = admin()
      heading_id = Ash.UUID.generate()
      text_id = Ash.UUID.generate()

      page =
        CMS.create_page!(
          %{
            title: "Doc",
            slug: slug(),
            block_tree: [
              %{"_type" => "heading", "id" => heading_id, "text" => "Otters", "level" => 2},
              %{"_type" => "rich_text", "id" => text_id, "legacy_html" => "<p>rivers</p>"}
            ]
          },
          actor: actor
        )

      {:ok, 2} = BlockIndexer.reindex(page)

      emptied =
        CMS.update_page!(
          page,
          %{
            block_tree: [
              %{"_type" => "heading", "id" => heading_id, "text" => "Otters", "level" => 2},
              %{"_type" => "rich_text", "id" => text_id, "legacy_html" => ""}
            ]
          },
          actor: actor
        )

      # Precondition: the block really is still there, just textless.
      assert length(emptied.blocks) == 2

      {:ok, _} = BlockIndexer.reindex(emptied)

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert [%{block_key: ^heading_id}] = rows
    end

    test "pruning is scoped to the document it re-indexed (#965)" do
      # Block keys are normally per-block UUIDs, so two documents rarely share
      # one — which would make a missing `document_id` filter invisible. The
      # rows are therefore written directly, under a deliberately shared key, so
      # the filter is actually exercised.
      actor = admin()
      shared_key = "shared-block-key"

      trim = page_with_blocks(actor, [%{type: :heading, content: "Trimmed", order: 0}])
      keep = page_with_blocks(actor, [%{type: :heading, content: "Kept", order: 0}])

      for page <- [trim, keep] do
        SearchIndex.upsert_block_embedding!(
          %{
            document_type: :page,
            document_id: page.id,
            block_key: shared_key,
            block_type: :quote,
            content_hash: "stale",
            ancestor_context: "",
            embedding: for(i <- 1..384, do: i * 1.0),
            embedded_at: DateTime.utc_now()
          },
          authorize?: false,
          tenant: page.org_id
        )
      end

      # Re-indexing `trim` produces no such key, so its copy is stale…
      {:ok, _} = BlockIndexer.reindex(trim)

      {:ok, trim_rows} = SearchIndex.block_embeddings_for(:page, trim.id, authorize?: false)

      refute Enum.any?(trim_rows, &(&1.block_key == shared_key)),
             "the stale row was not pruned"

      # …and the identically-keyed row on the OTHER document is untouched.
      {:ok, keep_rows} = SearchIndex.block_embeddings_for(:page, keep.id, authorize?: false)

      assert Enum.any?(keep_rows, &(&1.block_key == shared_key)),
             "pruning one document took another's rows"
    end

    test "an embedder outage does not delete the index it could not rebuild (#965)" do
      # The worst thing pruning could do. `live` is defined by the keys a run
      # produced, so a run that embedded nothing describes nothing — and with
      # id-less blocks whose keys shift, every old key looks stale. Deleting on
      # the strength of a failed read would leave a published document with no
      # vectors at all, and nothing re-enqueues indexing until the next fire.
      actor = admin()

      page =
        page_with_blocks(actor, [
          %{type: :heading, content: "Otters", order: 0},
          %{type: :rich_text, content: "<p>rivers and streams</p>", order: 1}
        ])

      {:ok, 2} = BlockIndexer.reindex(page)

      previous = Application.get_env(:kiln_cms, KilnCMS.Search, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Keyword.put(previous, :embedder, BrokenEmbedder)
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, previous) end)

      # Edited so every hash misses and the embedder is reached for each block.
      edited =
        CMS.update_page!(
          page,
          %{
            blocks: [
              %{type: :heading, content: "Otters rewritten", order: 0},
              %{type: :rich_text, content: "<p>rewritten body</p>", order: 1}
            ]
          },
          actor: actor
        )

      assert {:ok, 0} = BlockIndexer.reindex(edited)

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)

      assert length(rows) == 2,
             "an embedder outage wiped the index instead of leaving it stale"
    end

    test "a document whose blocks are NULL keeps its index (#965)" do
      # `pages.blocks` is nullable — no `null: false` in the migration — and an
      # import can leave it so. `to_typed(nil)` is `[]`, which pruning would
      # read as "every stored row is stale".
      actor = admin()
      page = page_with_blocks(actor, [%{type: :heading, content: "Otters", order: 0}])

      {:ok, 1} = BlockIndexer.reindex(page)

      assert {:ok, 0} = BlockIndexer.reindex(%{page | blocks: nil})

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert length(rows) == 1, "a NULL blocks column wiped the index"
    end

    test "a select-limited record is a no-op rather than a crash (#965)" do
      actor = admin()
      page = page_with_blocks(actor, [%{type: :heading, content: "Otters", order: 0}])

      {:ok, 1} = BlockIndexer.reindex(page)

      assert {:ok, 0} = BlockIndexer.reindex(%{page | blocks: %Ash.NotLoaded{field: :blocks}})

      {:ok, rows} = SearchIndex.block_embeddings_for(:page, page.id, authorize?: false)
      assert length(rows) == 1
    end

    test "pruning does not cross orgs, even for the same document id and key (#965)" do
      # Two orgs can hold the same `document_id` after a content copy or
      # promotion, and `idx-N` keys collide trivially, so this is the axis the
      # same-org test above cannot reach.
      #
      # What makes it hold is the destroy filtering on the row's PRIMARY KEY:
      # the ids come from a read already scoped to this tenant and document, so
      # they cannot name a foreign row whatever the keys collide with. Removing
      # the `tenant:` from the destroy alone does NOT fail this — that option
      # scopes the query, it is not the thing preventing the cross-org delete.
      actor = admin()
      other = org("otherorg")

      page = page_with_blocks(actor, [%{type: :heading, content: "Otters", order: 0}])
      shared_key = "cross-org-key"

      for tenant <- [page.org_id, other] do
        SearchIndex.upsert_block_embedding!(
          %{
            document_type: :page,
            document_id: page.id,
            block_key: shared_key,
            block_type: :quote,
            content_hash: "stale",
            ancestor_context: "",
            embedding: for(i <- 1..384, do: i * 1.0),
            embedded_at: DateTime.utc_now()
          },
          authorize?: false,
          tenant: tenant
        )
      end

      {:ok, _} = BlockIndexer.reindex(page)

      {:ok, other_rows} =
        SearchIndex.block_embeddings_for(:page, page.id, authorize?: false, tenant: other)

      assert Enum.any?(other_rows, &(&1.block_key == shared_key)),
             "pruning one org's rows took another org's"
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

  describe "filtered recall (#998)" do
    # What this pins is the SETTING, on every connection — which is exactly what
    # this codebase contributes. Whether iterative scanning then recovers the
    # filtered rows is pgvector's behaviour, not ours, and testing it here needs
    # the planner to actually choose the HNSW index.
    #
    # It does not, at any fixture size worth putting in a suite. A first version
    # of this test seeded 250 rows in a big org and 3 in a small one, forced
    # `enable_seqscan = off`, and asserted the small org's rows came back — and
    # it passed with `hnsw.iterative_scan = off` at every seed tried, because
    # `EXPLAIN` shows a Bitmap Index Scan on the `org_id`-leading btree feeding a
    # Sort. That plan is EXACT: filter-then-sort beats an ANN scan whenever the
    # filtered set is small, which at test scale it always is. The assertion was
    # about Postgres picking a different plan than it picks, so it proved
    # nothing about the fix.
    #
    # So: assert the thing we control, and say plainly that the recall behaviour
    # downstream of it is pgvector's contract, documented in
    # `KilnCMS.Search.BlockSearch` and `docs/semantic-search-plan.md`.
    test "every connection has iterative scanning on, so a filtered scan can resume" do
      %{rows: [[mode]]} = KilnCMS.Repo.query!("SHOW hnsw.iterative_scan", [])

      assert mode == "strict_order",
             "filtered vector searches lose rows the tenant filter rejects without this"
    end

    test "the setting survives a checkout, not just the first connection" do
      # `after_connect` runs per connection, and the pool has several. A setting
      # applied to only the one the first query happened to get would look right
      # in a single-query test and be wrong in production.
      modes =
        for _ <- 1..5 do
          %{rows: [[mode]]} = KilnCMS.Repo.query!("SHOW hnsw.iterative_scan", [])
          mode
        end

      assert Enum.uniq(modes) == ["strict_order"]
    end
  end
end
