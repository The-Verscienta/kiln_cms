defmodule KilnCMS.Search.BlockIndexer do
  @moduledoc """
  Computes and stores per-block embeddings for a document (Kiln v2 — decision D16).

  Walks the typed block tree, projects each block's `search_text` plus its
  ancestor context (the document title — hierarchical embeddings), and upserts a
  `BlockEmbedding`. Blocks whose `content_hash` is unchanged are skipped, so
  re-indexing only embeds what actually changed. Assumes semantic search is
  enabled (the worker guards that).
  """
  require Ash.Query

  alias KilnCMS.{Blocks, Search, SearchIndex}
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Search.VectorCache

  @doc "Re-index a document's blocks. Returns `{:ok, count_embedded}`."
  @spec reindex(struct()) :: {:ok, non_neg_integer()}
  def reindex(document) do
    case Map.get(document, :blocks) do
      blocks when is_list(blocks) -> reindex_blocks(document, blocks)
      # Not loaded (a select-limited read) or NULL (the column is nullable, and
      # an import can leave it so). Both used to be harmless; they are not any
      # more, because `prune_stale/3` would read "no blocks" as "every stored
      # row is stale" and delete the document's whole index. Answering "nothing
      # embedded" is the only safe reading of "I cannot see the blocks".
      _unloaded_or_null -> {:ok, 0}
    end
  end

  defp reindex_blocks(document, blocks) do
    type = Engine.document_type(document)
    # Block embeddings are tenant-scoped (epic #336); the tenant rides on the
    # document's own `org_id`.
    org_id = document.org_id
    context = document_context(document)
    existing = existing_rows(org_id, type, document.id)
    hashes = Map.new(existing, &{&1.block_key, &1.content_hash})

    indexed =
      blocks
      |> TypedBlocks.to_typed()
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        index_block(org_id, type, document.id, block, index, context, hashes)
      end)

    prune_stale(org_id, existing, indexed)

    {:ok, Enum.count(indexed, fn {_key, status} -> status == :embedded end)}
  end

  # Rows for blocks the document no longer has (#965).
  #
  # `upsert` is the only write, so without this the index only ever grows: a
  # block that was deleted, or whose `search_text` became empty, or an id-less
  # block that moved and so re-keyed from `idx-3` to `idx-1`, all leave their old
  # row behind. `Related.centroid/1` averages **every** stored row for the
  # document, so the centroid keeps describing text the page does not contain —
  # and `BlockSearch` keeps returning it.
  #
  # It also makes the two centroid paths agree. The computed one (#852) is built
  # from the current blocks by construction; the stored one only matches it once
  # the strays are gone.
  #
  # One statement rather than a destroy per row: this runs inside
  # `BlockEmbeddingWorker` on every fire, and the common case deletes nothing.
  #
  # **Skipped entirely if any block failed to embed.** The keys a run produces
  # are what defines "stale", so a run that embedded nothing has a key set that
  # describes nothing. With the embedder down (serving not started, OOM) and a
  # document whose keys shifted — an id-less legacy tree with a block inserted
  # at the top re-keys every `idx-N` — every block answers `:error` under a NEW
  # key, and pruning would then delete the entire index for a document whose
  # rows were the only copy. Deleting on the strength of a failed read is the
  # one thing this must never do; leaving the old rows in place is exactly the
  # behaviour that predates #965, so the degraded state is the old state.
  defp prune_stale(org_id, existing, indexed) do
    if Enum.any?(indexed, fn {_key, status} -> status == :error end) do
      :ok
    else
      destroy_stale(org_id, existing, indexed)
    end
  end

  # Filtered on the primary key rather than on `{document, block_key}`: the ids
  # come from a read already scoped to this tenant and document, so they cannot
  # name a row belonging to another of either, whatever a block key collides
  # with.
  defp destroy_stale(org_id, existing, indexed) do
    live = indexed |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> MapSet.new()
    stale = for row <- existing, not MapSet.member?(live, row.block_key), do: row.id

    if stale != [] do
      KilnCMS.Search.BlockEmbedding
      |> Ash.Query.filter(id in ^stale)
      |> Ash.bulk_destroy!(:destroy, %{},
        authorize?: false,
        tenant: org_id,
        strategy: [:atomic, :stream],
        return_errors?: true
      )
    end

    :ok
  end

  @doc """
  The vectors `reindex/1` *would* store, computed and thrown away (#852).

  Block embeddings are only written by firing, and firing runs on publish — so a
  document that has never been published has no vectors, and near-duplicate
  detection, which is a **pre**-publication check, could not run on exactly the
  case it exists for.

  This is the anchor-side answer, and it deliberately stores nothing.
  `block_embeddings` rows carry `ancestor_context` — block text copied out of
  the document — with no state or audience column to filter on, which is why
  their read policy is editor-only (#565). Writing a draft's blocks there would
  put unpublished text into an index whose other consumers
  (`KilnCMS.Search.BlockSearch`, and anything added later) have nothing to
  exclude it *by*. Keeping the draft's vectors in memory keeps that property.

  The projection is shared with `reindex/1` down to the concatenation, because
  the whole point is to produce a vector comparable with the stored ones. A
  second spelling of `"\#{context}\\n\\n\#{text}"` here would silently place the
  anchor in a slightly different space and quietly degrade every distance.

  Memoized per input by `KilnCMS.Search.VectorCache`, so editing one paragraph
  of a long draft re-embeds that paragraph and reuses the rest — the stored path
  gets the same reuse from `content_hash`, and this is its equivalent (#964).
  """
  @spec block_vectors(struct()) :: [[float()]]
  def block_vectors(document) do
    document
    |> embedding_inputs()
    |> Enum.flat_map(fn input ->
      case VectorCache.embed(input) do
        nil -> []
        vector -> [vector]
      end
    end)
  end

  @doc """
  Exactly the strings `block_vectors/1` would embed, in order.

  One function rather than two so a caller can key a cache on the inputs and
  then embed the same list: a fingerprint computed by a second walk would have
  to be kept in lockstep with this one by hand, and a skip rule added to only
  one of them would leave the key no longer describing the value.

  Returns `[]` for a document whose `blocks` were not loaded — a select-limited
  read (`teaser_fields`) is a legitimate shape, and the old stored-vector path
  answered "no centroid" for it rather than raising.
  """
  @spec embedding_inputs(struct()) :: [String.t()]
  def embedding_inputs(document) do
    case Map.get(document, :blocks) do
      blocks when is_list(blocks) ->
        context = document_context(document)

        blocks
        |> TypedBlocks.to_typed()
        |> Enum.flat_map(&embedding_input(&1, context))

      _unloaded_or_absent ->
        []
    end
  end

  defp embedding_input(block, context) do
    case Blocks.search_text(block) do
      "" -> []
      text -> ["#{context}\n\n#{text}"]
    end
  end

  # Answers `{block_key | nil, status}`. The key is what `prune_stale/3` diffs
  # against the stored rows, and it is `nil` for a block that contributes no
  # text — deliberately, so a block whose body was emptied has its row deleted
  # rather than left describing what used to be there.
  defp index_block(org_id, type, document_id, %module{} = block, index, context, hashes) do
    text = Blocks.search_text(block)

    if text == "" do
      {nil, :skip}
    else
      block_key = block_key(block, index)
      hash = hash(text, context)

      if hashes[block_key] == hash do
        {block_key, :unchanged}
      else
        {block_key,
         embed_and_store(org_id, type, document_id, block_key, module, hash, context, text)}
      end
    end
  end

  defp embed_and_store(org_id, type, document_id, block_key, module, hash, context, text) do
    case Search.embed("#{context}\n\n#{text}") do
      {:ok, vector} ->
        SearchIndex.upsert_block_embedding(
          %{
            document_type: type,
            document_id: document_id,
            block_key: block_key,
            block_type: Kiln.Block.Info.name(module),
            content_hash: hash,
            ancestor_context: context,
            embedding: vector,
            embedded_at: DateTime.utc_now()
          },
          authorize?: false,
          tenant: org_id
        )

        :embedded

      _ ->
        :error
    end
  end

  # One batched read of the document's stored hashes (embedding vectors stay in
  # the DB) instead of a lookup query per block.
  defp existing_rows(org_id, type, document_id) do
    SearchIndex.block_embeddings_for!(type, document_id,
      authorize?: false,
      tenant: org_id,
      query: [select: [:id, :block_key, :content_hash]]
    )
  end

  defp block_key(block, index), do: Map.get(block, :id) || "idx-#{index}"

  defp document_context(document), do: Map.get(document, :title) || ""

  defp hash(text, context), do: Integer.to_string(:erlang.phash2({text, context}))
end
