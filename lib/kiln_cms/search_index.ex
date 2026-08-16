defmodule KilnCMS.SearchIndex do
  @moduledoc """
  Block-granular search index domain (Kiln v2 — decision D16).

  Holds `BlockEmbedding` — `KilnCMS.Search.BlockIndexer` populates it
  (embed-on-fire), `KilnCMS.Search.BlockSearch` queries it — and `TagEmbedding`
  (#1085), filled lazily by `KilnCMS.Search.Related.suggest_tags/2`.
  """
  use Ash.Domain

  resources do
    resource KilnCMS.Search.BlockEmbedding do
      define :upsert_block_embedding, action: :upsert
      define :block_embeddings_for, action: :for_document, args: [:document_type, :document_id]
      define :nearest_block_embeddings, action: :nearest_to_vector

      define :get_block_embedding,
        action: :read,
        get_by: [:document_type, :document_id, :block_key]
    end

    # Persisted tag-name vectors for `Search.Related.suggest_tags/2` (#1085).
    resource KilnCMS.Search.TagEmbedding do
      define :upsert_tag_embedding, action: :upsert
      define :tag_embeddings_for, action: :for_tags, args: [:tag_ids]
      define :nearest_tag_embeddings, action: :nearest_to_vector
    end
  end
end
