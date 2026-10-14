defmodule KilnCMS.Search.BlockEmbeddingPrefixesTest do
  @moduledoc """
  The block path embeds with the instruction prefixes (#1939).

  Asymmetric retrieval models (the e5 family) expect `"passage: "` on content
  and `"query: "` on the query. Documents and tags already went through
  `Search.embed_document/1`; blocks and the `:nearest` query went through the
  raw `Search.embed/1`, so under e5 the block leg compared unprefixed block
  vectors with a prefixed query vector.

  These assert on the **strings that reach the adapter**, recorded by a stub
  embedder, because the vectors cannot show it: a stub's output is a function
  of its input, so a wrong prefix still yields a well-formed vector.
  """
  # async: false — swaps the global embedder and prefixes in the
  # `KilnCMS.Search` app env, and shares the one VectorCache instance.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.{CMS, SearchIndex}
  alias KilnCMS.Search.{BlockIndexer, BlockSearch, VectorCache}

  # Reports every input to the test process. By message rather than a return
  # value because `VectorCache.embed/1` runs its fallback inside a Cachex
  # courier — another process — so the test pid is looked up, not `self()`.
  defmodule RecordingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      send(:persistent_term.get({__MODULE__, :pid}), {:embedded, text})
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  setup do
    :persistent_term.put({RecordingEmbedder, :pid}, self())
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Cachex.clear(VectorCache.cache_name())
      :persistent_term.erase({RecordingEmbedder, :pid})
    end)

    Cachex.clear(VectorCache.cache_name())
    configure(original, query_prefix: "", document_prefix: "")

    %{original: original}
  end

  defp configure(base, opts) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      base |> Keyword.merge(semantic: true, embedder: RecordingEmbedder) |> Keyword.merge(opts)
    )
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "blkprefix-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(title, blocks) do
    CMS.create_page!(
      %{
        title: title,
        slug: "blkprefix-#{System.unique_integer([:positive])}",
        blocks: KilnCMS.TypedFixtures.typed_blocks(blocks)
      },
      actor: admin()
    )
  end

  defp otters, do: page("Otters", [%{type: :heading, content: "Rivers and streams", order: 0}])

  # Everything the embedder was handed so far, oldest first.
  defp embedded(acc \\ []) do
    receive do
      {:embedded, text} -> embedded([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "with e5-style prefixes" do
    setup %{original: original} do
      configure(original, query_prefix: "query: ", document_prefix: "passage: ")
      :ok
    end

    test "the stored path embeds a block document-side, prefix before the context line" do
      doc = otters()
      _ = embedded()

      assert {:ok, 1} = BlockIndexer.reindex(doc)

      # The whole string, not `starts_with?`: the context line has to follow
      # the prefix, and a prefix spliced in after it would satisfy a
      # starts-with on the context instead.
      assert embedded() == ["passage: Otters\n\nRivers and streams"]
    end

    test "the compute-on-demand path embeds the same string the stored path does" do
      # `block_vectors/1` exists to produce vectors comparable with the stored
      # ones (#852); a prefix on one path and not the other puts the draft's
      # anchor in a different region of the space from everything it is
      # compared against.
      doc = otters()
      _ = embedded()

      assert [_vector] = BlockIndexer.block_vectors(doc)
      assert embedded() == ["passage: Otters\n\nRivers and streams"]
    end

    test ":nearest embeds its query argument query-side" do
      {:ok, 1} = BlockIndexer.reindex(otters())
      _ = embedded()

      assert [_hit] = BlockSearch.search("otter habitat")
      assert embedded() == ["query: otter habitat"]
    end

    test "changing the document prefix re-embeds blocks on the next reindex", %{
      original: original
    } do
      # The upgrade note says a firing sweep re-indexes blocks after a prefix
      # change. That is only true if `content_hash` notices: hashed on
      # `{text, context}` alone, every block answers `:unchanged` and the sweep
      # re-embeds nothing.
      doc = otters()
      configure(original, query_prefix: "", document_prefix: "")
      {:ok, 1} = BlockIndexer.reindex(doc)
      assert {:ok, 0} = BlockIndexer.reindex(doc)

      configure(original, query_prefix: "query: ", document_prefix: "passage: ")
      _ = embedded()

      assert {:ok, 1} = BlockIndexer.reindex(doc)
      assert embedded() == ["passage: Otters\n\nRivers and streams"]
      assert {:ok, 0} = BlockIndexer.reindex(doc)
    end
  end

  describe "with the default empty prefixes" do
    test "every input is byte-identical to the unprefixed one" do
      # The upgrade promise: a bge-small deployment (no prefixes) re-embeds
      # nothing, because nothing it sends the model changed.
      doc = otters()
      _ = embedded()

      {:ok, 1} = BlockIndexer.reindex(doc)
      _ = BlockIndexer.block_vectors(doc)
      _ = BlockSearch.search("otter habitat")

      assert embedded() == [
               "Otters\n\nRivers and streams",
               "Otters\n\nRivers and streams",
               "otter habitat"
             ]
    end

    test "the stored content_hash is the pre-#1939 hash, so no block re-embeds on upgrade" do
      doc = otters()
      {:ok, 1} = BlockIndexer.reindex(doc)

      {:ok, [row]} = SearchIndex.block_embeddings_for(:page, doc.id, authorize?: false)

      assert row.content_hash ==
               Integer.to_string(:erlang.phash2({"Rivers and streams", "Otters"}))
    end
  end

  test "the VectorCache key differs by pooling", %{original: original} do
    # CLS and mean pooling of the same hidden states are different vectors for
    # one string; a key that ignores pooling serves one as the other.
    configure(original, pooling: :cls_token_pooling)
    cls = VectorCache.key("same text")

    configure(original, pooling: :mean_pooling)
    mean = VectorCache.key("same text")

    refute cls == mean
  end
end
