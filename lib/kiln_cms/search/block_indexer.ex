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
    context = document_context(document)

    embedded =
      document
      |> Map.get(:blocks)
      |> TypedBlocks.to_typed()
      |> Enum.with_index()
      |> Enum.map(fn {block, index} -> index_block(type, document.id, block, index, context) end)
      |> Enum.count(&(&1 == :embedded))

    {:ok, embedded}
  end

  defp index_block(type, document_id, %module{} = block, index, context) do
    text = Blocks.search_text(block)

    if text == "" do
      :skip
    else
      block_key = block_key(block, index)
      hash = hash(text, context)

      if unchanged?(type, document_id, block_key, hash) do
        :unchanged
      else
        embed_and_store(type, document_id, block_key, module, hash, context, text)
      end
    end
  end

  defp embed_and_store(type, document_id, block_key, module, hash, context, text) do
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
          authorize?: false
        )

        :embedded

      _ ->
        :error
    end
  end

  defp unchanged?(type, document_id, block_key, hash) do
    case SearchIndex.get_block_embedding(type, document_id, block_key, authorize?: false) do
      {:ok, %{content_hash: ^hash}} -> true
      _ -> false
    end
  end

  defp block_key(block, index), do: Map.get(block, :id) || "idx-#{index}"

  defp document_context(document), do: Map.get(document, :title) || ""

  defp hash(text, context), do: Integer.to_string(:erlang.phash2({text, context}))
end
