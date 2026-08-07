defmodule KilnCMS.Search.BlockIndexer do
  @moduledoc """
  Computes and stores per-block embeddings for a document (Kiln v2 — decision D16).

  Walks the typed block tree, projects each block's `search_text` plus its
  ancestor context (the document title — hierarchical embeddings), and upserts a
  `BlockEmbedding`. Blocks whose `content_hash` is unchanged are skipped, so
  re-indexing only embeds what actually changed. Assumes semantic search is
  enabled (the worker guards that).
  """
  alias KilnCMS.{Blocks, Search, SearchIndex}
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.Engine

  @doc "Re-index a document's blocks. Returns `{:ok, count_embedded}`."
  @spec reindex(struct()) :: {:ok, non_neg_integer()}
  def reindex(document) do
    type = Engine.document_type(document)
    # Block embeddings are tenant-scoped (epic #336); the tenant rides on the
    # document's own `org_id`.
    org_id = document.org_id
    context = document_context(document)
    hashes = existing_hashes(org_id, type, document.id)

    embedded =
      document
      |> Map.get(:blocks)
      |> TypedBlocks.to_typed()
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        index_block(org_id, type, document.id, block, index, context, hashes)
      end)
      |> Enum.count(&(&1 == :embedded))

    {:ok, embedded}
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
  """
  @spec block_vectors(struct()) :: [[float()]]
  def block_vectors(document) do
    document
    |> embedding_inputs()
    |> Enum.flat_map(fn input ->
      case Search.embed(input) do
        {:ok, vector} -> [vector]
        _error -> []
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

  defp index_block(org_id, type, document_id, %module{} = block, index, context, hashes) do
    text = Blocks.search_text(block)

    if text == "" do
      :skip
    else
      block_key = block_key(block, index)
      hash = hash(text, context)

      if hashes[block_key] == hash do
        :unchanged
      else
        embed_and_store(org_id, type, document_id, block_key, module, hash, context, text)
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
  defp existing_hashes(org_id, type, document_id) do
    type
    |> SearchIndex.block_embeddings_for!(document_id,
      authorize?: false,
      tenant: org_id,
      query: [select: [:block_key, :content_hash]]
    )
    |> Map.new(&{&1.block_key, &1.content_hash})
  end

  defp block_key(block, index), do: Map.get(block, :id) || "idx-#{index}"

  defp document_context(document), do: Map.get(document, :title) || ""

  defp hash(text, context), do: Integer.to_string(:erlang.phash2({text, context}))
end
