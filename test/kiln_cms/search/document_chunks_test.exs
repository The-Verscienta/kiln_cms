defmodule KilnCMS.Search.DocumentChunksTest do
  @moduledoc """
  Chunked document embeddings (#1940): with `chunk_long_documents` on, the
  embedding pipeline also embeds the part of a long record's `search_text`
  past the model's window, and the block leg of `hybrid/3` reaches a record
  through its nearest chunk — so a record whose only match is past the window
  is found, and the relevance floor judges it by that chunk.

  The stub embedder here models the one property of a real model the
  feature exists for: it **truncates** — it sees only the first
  `@window_words` words of what it is given, as a real model sees only its
  first window of tokens. A text whose first window mentions the marker
  embeds to a fixed unit vector, every other text to a hash-derived one far
  from it, so "found by its chunk" is a distance of exactly 0.
  """
  # async: false — swaps the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  import KilnCMS.TypedFixtures

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.{Chunker, DocumentChunkIndexer}
  alias KilnCMS.SearchIndex

  # `sequence_length: 100` → a 60-word window (`Chunker.words_for/1`).
  @sequence_length 100
  @window_words 60

  # The word that sits past the window, and the query that "means" it — no
  # lexeme in common, so no lexical leg can find the record: only a vector
  # can.
  @marker "quokkamarker"
  @query "small marsupial"

  defmodule TruncatingEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder

    @window_words 60

    @impl true
    def embed(text) do
      seen = text |> String.split() |> Enum.take(@window_words) |> Enum.join(" ")

      if seen =~ "quokkamarker" or seen =~ "small marsupial" do
        # Unit vector: a hash-derived vector below is ≥ ~0.9 from it.
        {:ok, [1.0 | List.duplicate(0.0, 383)]}
      else
        seed = :erlang.phash2(seen)
        {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
      end
    end
  end

  defmodule FailingEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: {:error, :serving_down}
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    put_search_env(
      semantic: true,
      embedder: TruncatingEmbedder,
      sequence_length: @sequence_length,
      chunk_overlap: 10,
      chunk_long_documents: true,
      # Chunks are charged to the embedding budget, and the default org's
      # bucket is shared with every other suite in this window: generous
      # here, tightened per test (on a private org) under "the embedding
      # budget" below.
      embedding_per_org_limit: {1_000_000, :timer.hours(1)}
    )

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "chunk-#{uniq()}"
  defp system, do: KilnCMS.SystemActor.new(:search)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "chunk-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{uniq()}",
      status: :active
    })
  end

  # `n` filler words with the marker as the last one — well past a 60-word
  # window for any n much over 60.
  defp long_body(n, marker \\ @marker) do
    filler = Enum.map_join(1..n, " ", &"filler#{rem(&1, 37)}")
    "<p>#{filler} #{marker}</p>"
  end

  defp long_page(admin, opts \\ []) do
    CMS.create_page!(
      %{
        title: "Wildlife notes",
        slug: slug(),
        blocks:
          typed_blocks([
            %{type: :rich_text, content: Keyword.get(opts, :body, long_body(200)), order: 0}
          ])
      },
      Keyword.merge([actor: admin], Keyword.take(opts, [:tenant]))
    )
  end

  defp chunks_of(page, tenant \\ nil) do
    SearchIndex.document_chunk_embeddings_for!(:page, page.id,
      actor: system(),
      tenant: tenant || page.org_id
    )
    |> Enum.sort_by(& &1.chunk_index)
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp hit_ids(results), do: Enum.map(results, & &1.id)

  describe "the pipeline" do
    test "a long record gets one row per chunk, each the embedding of its chunk text" do
      page = long_page(user(:admin))
      KilnCMS.DataCase.drain_oban()

      page = reload(page)
      inputs = DocumentChunkIndexer.inputs(page, page.search_text)
      assert length(inputs) >= 2, "premise: the body runs several windows past the first"

      rows = chunks_of(page)
      assert Enum.map(rows, & &1.chunk_index) == Enum.to_list(0..(length(inputs) - 1))

      for {row, input} <- Enum.zip(rows, inputs) do
        # pgvector stores float4, so compare to that precision.
        {:ok, expected} = Search.embed_document(input)

        assert Enum.zip(row.embedding, expected)
               |> Enum.all?(fn {a, b} -> abs(a - b) < 1.0e-6 end)
      end

      # The marker is past the window: the document's own vector never saw it…
      refute page.embedding == [1.0 | List.duplicate(0.0, 383)]
      # …and the last chunk did.
      assert List.last(rows).embedding == [1.0 | List.duplicate(0.0, 383)]
    end

    test "a record the window covers gets no rows" do
      page = long_page(user(:admin), body: "<p>short and sweet</p>")
      KilnCMS.DataCase.drain_oban()
      assert chunks_of(page) == []
    end

    test "turning the knob off writes no chunk row and changes no stored vector" do
      admin = user(:admin)

      put_search_env(chunk_long_documents: false)
      off = long_page(admin, body: long_body(200, "same"))
      KilnCMS.DataCase.drain_oban()
      assert chunks_of(off) == []

      put_search_env(chunk_long_documents: true)
      on = long_page(admin, body: long_body(200, "same"))
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(on) == []

      # The document's own vector is the same either way: chunks are added
      # beside it, never folded into it.
      assert reload(off).embedding == reload(on).embedding

      # And switching it off afterwards leaves the rows a re-embed would
      # otherwise rewrite exactly as they were — nothing is read or written.
      before = chunks_of(on)
      put_search_env(chunk_long_documents: false)

      CMS.update_page!(
        on,
        %{blocks: typed_blocks([%{type: :rich_text, content: "<p>x</p>", order: 0}])},
        actor: admin
      )

      KilnCMS.DataCase.drain_oban()
      assert chunks_of(on) == before
    end

    test "chunks are replaced on re-embed, kept when unchanged, and removed when the text shrinks" do
      admin = user(:admin)
      page = long_page(admin)
      KilnCMS.DataCase.drain_oban()
      first = chunks_of(page)

      # A save that does not touch the text past the window rewrites nothing.
      CMS.update_page!(reload(page), %{slug: slug()}, actor: admin)
      KilnCMS.DataCase.drain_oban()
      page = reload(page)
      assert Enum.map(chunks_of(page), & &1.id) == Enum.map(first, & &1.id)

      # New text past the window: a new set, matching the new inputs.
      CMS.update_page!(
        page,
        %{
          blocks: typed_blocks([%{type: :rich_text, content: long_body(300, "otter"), order: 0}])
        },
        actor: admin
      )

      KilnCMS.DataCase.drain_oban()
      page = reload(page)
      replaced = chunks_of(page)
      inputs = DocumentChunkIndexer.inputs(page, page.search_text)
      assert length(replaced) == length(inputs)
      refute Enum.map(replaced, & &1.content_hash) == Enum.map(first, & &1.content_hash)

      # Shrunk back inside the window: none.
      CMS.update_page!(
        page,
        %{blocks: typed_blocks([%{type: :rich_text, content: "<p>brief</p>", order: 0}])},
        actor: admin
      )

      KilnCMS.DataCase.drain_oban()
      assert chunks_of(page) == []
    end

    test "a failed embed leaves the stored chunks as they were" do
      admin = user(:admin)
      page = long_page(admin)
      KilnCMS.DataCase.drain_oban()
      page = reload(page)
      before = chunks_of(page)

      put_search_env(embedder: FailingEmbedder)

      assert {:error, :serving_down} =
               DocumentChunkIndexer.reindex(page, page.org_id, page.search_text <> " more words")

      assert chunks_of(page) == before
    end

    test "locking a record clears its chunks (#496), whatever the knob says now" do
      admin = user(:admin)
      page = long_page(admin) |> then(&CMS.publish_page!(&1, actor: admin))
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(page) == []

      put_search_env(chunk_long_documents: false)
      CMS.update_page!(reload(page), %{access_password: "shared secret"}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert chunks_of(page) == []
    end

    test "a hard purge removes the chunks; a soft delete keeps them" do
      admin = user(:admin)
      page = long_page(admin)
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(page) == []

      CMS.destroy_page!(reload(page), actor: admin)
      refute chunks_of(page) == []

      trashed =
        KilnCMS.CMS.Page
        |> Ash.Query.for_read(:trashed)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!(authorize?: false, tenant: page.org_id)

      CMS.purge_page!(trashed, actor: admin)
      assert chunks_of(page) == []
    end
  end

  describe "the embedding budget" do
    # A private org per test: the org bucket is keyed by org id, so no other
    # test's spend reaches these counts.
    defp spent(org), do: KilnCMS.LLM.Budget.get("search_embedding:org:#{org.id}", :timer.hours(1))

    defp embedding_job(page) do
      %{"org_id" => page.org_id, "resource" => to_string(KilnCMS.CMS.Page), "id" => page.id}
    end

    defp rewrite_past_window(page, admin) do
      CMS.update_page!(
        page,
        %{
          blocks: typed_blocks([%{type: :rich_text, content: long_body(300, "otter"), order: 0}])
        },
        actor: admin,
        tenant: page.org_id
      )
    end

    test "each chunk that reaches the model costs one unit; a reused chunk is free" do
      admin = user(:admin)
      org = org("chunkbudget")
      put_search_env(embedding_unattended_share: 1.0)

      page = long_page(admin, tenant: org)
      KilnCMS.DataCase.drain_oban()
      rows = chunks_of(page, org.id)
      assert length(rows) >= 2
      assert spent(org) == length(rows)

      # Nothing past the window changed: every chunk is reused, nothing charged.
      CMS.update_page!(reload(page), %{slug: slug()}, actor: admin, tenant: org.id)
      KilnCMS.DataCase.drain_oban()
      assert spent(org) == length(rows)
    end

    test "a spent window snoozes the job, charges nothing and leaves the chunks" do
      admin = user(:admin)
      org = org("chunkspent")
      put_search_env(embedding_unattended_share: 1.0)

      page = long_page(admin, tenant: org)
      KilnCMS.DataCase.drain_oban()
      before = chunks_of(page, org.id)
      charged = spent(org)

      # One unit of room left; the rewrite needs several.
      put_search_env(embedding_per_org_limit: {charged + 1, :timer.hours(1)})
      page = rewrite_past_window(reload(page), admin)

      assert {:snooze, seconds} =
               Oban.Testing.perform_job(KilnCMS.Search.EmbeddingWorker, embedding_job(page),
                 repo: KilnCMS.Repo
               )

      assert seconds in 1..3600
      # Refused before charging: a Hammer window counts a refused charge too.
      assert spent(org) == charged
      assert chunks_of(page, org.id) == before
    end

    test "a budget that can never hold the document clears its chunks" do
      admin = user(:admin)
      org = org("chunkdisabled")
      put_search_env(embedding_unattended_share: 1.0)

      page = long_page(admin, tenant: org)
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(page, org.id) == []

      # Share 0: unattended work is off for good, so waiting would never end,
      # and keeping the old chunks would vouch for text the record lost.
      put_search_env(embedding_unattended_share: 0.0)
      page = rewrite_past_window(reload(page), admin)

      assert :ok =
               Oban.Testing.perform_job(KilnCMS.Search.EmbeddingWorker, embedding_job(page),
                 repo: KilnCMS.Repo
               )

      assert chunks_of(page, org.id) == []
    end
  end

  describe "search" do
    test "a record whose only match is past the window is found through its chunk" do
      admin = user(:admin)
      page = long_page(admin)
      KilnCMS.DataCase.drain_oban()

      # A floor every hash-derived distance fails: only a distance-0 vector
      # — the chunk that holds the marker — can keep a semantic-only hit.
      put_search_env(semantic_max_distance: 0.05)

      [hit] = Enum.filter(Search.hybrid(:page, @query, actor: admin), &(&1.id == page.id))
      assert :block in Search.hit_legs(hit)
      refute Enum.any?(Search.hit_legs(hit), &(&1 in [:keyword, :keyword_any, :title, :fuzzy]))

      # The block leg runs on chunks alone, too — `block_leg: false` is about
      # block rows.
      put_search_env(block_leg: false)
      assert page.id in hit_ids(Search.hybrid(:page, @query, actor: admin))

      # Off: the document's head vector is all the floor has, and it fails.
      put_search_env(chunk_long_documents: false)
      refute page.id in hit_ids(Search.hybrid(:page, @query, actor: admin))
    end

    test "the floor judges by min(head, chunk): a chunk beyond the floor does not rescue" do
      admin = user(:admin)
      # The marker is not in the text at all — every chunk is hash-derived.
      page = long_page(admin, body: long_body(200, "nothing"))
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(page) == []

      put_search_env(semantic_max_distance: 0.05)
      refute page.id in hit_ids(Search.hybrid(:page, @query, actor: admin))
    end

    test "another org's chunks are neither readable nor searchable" do
      admin = user(:admin)
      a = org("chunka")
      b = org("chunkb")

      page_b = long_page(admin, tenant: b)
      KilnCMS.DataCase.drain_oban()
      refute chunks_of(page_b, b.id) == []

      {:ok, vector} = Search.embed_query(@query)

      assert SearchIndex.nearest_document_chunk_embeddings!(
               %{vector: vector, document_type: :page},
               actor: system(),
               tenant: a.id
             ) == []

      assert SearchIndex.document_chunk_embeddings_for!(:page, page_b.id,
               actor: system(),
               tenant: a.id
             ) ==
               []

      put_search_env(semantic_max_distance: 0.05)

      refute page_b.id in hit_ids(Search.hybrid(:page, @query, tenant: a, authorize?: false))
      assert page_b.id in hit_ids(Search.hybrid(:page, @query, tenant: b, authorize?: false))
    end
  end

  describe "policies — the indexer writes, editors and the system read" do
    defp row_attrs do
      %{
        document_type: :page,
        document_id: Ash.UUID.generate(),
        chunk_index: 0,
        content_hash: String.duplicate("a", 64),
        embedding: [1.0 | List.duplicate(0.0, 383)],
        embedded_at: DateTime.utc_now()
      }
    end

    defp org_id, do: KilnCMS.Accounts.default_org_id()

    test "only the search system actor may write a row" do
      for actor <- [nil, user(:viewer), user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 SearchIndex.create_document_chunk_embedding(row_attrs(),
                   actor: actor,
                   tenant: org_id()
                 )
      end

      assert {:ok, row} =
               SearchIndex.create_document_chunk_embedding(row_attrs(),
                 actor: system(),
                 tenant: org_id()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               SearchIndex.destroy_document_chunk_embedding(row,
                 actor: user(:admin),
                 tenant: org_id()
               )

      assert :ok =
               SearchIndex.destroy_document_chunk_embedding(row,
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the system and editors read the index; a viewer or anonymous caller does not" do
      {:ok, row} =
        SearchIndex.create_document_chunk_embedding(row_attrs(),
          actor: system(),
          tenant: org_id()
        )

      read = fn actor ->
        SearchIndex.document_chunk_embeddings_for!(:page, row.document_id,
          actor: actor,
          tenant: org_id()
        )
      end

      assert [%{id: id}] = read.(system())
      assert id == row.id
      assert [_] = read.(user(:editor))
      assert read.(user(:viewer)) == []
      assert read.(nil) == []
    end
  end

  test "the test's window is the chunker's" do
    # Keeps the stub's truncation and the chunker's arithmetic in step.
    assert Chunker.words_for(@sequence_length) == @window_words
  end
end
