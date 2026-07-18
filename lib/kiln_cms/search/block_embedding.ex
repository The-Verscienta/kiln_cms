defmodule KilnCMS.Search.BlockEmbedding do
  @moduledoc """
  A per-block embedding (Kiln v2 — decision D16).

  Each block is the natural unit for retrieval, so "find the relevant section"
  becomes a first-class query. The embedding is computed over the block's
  `search_text` plus its `ancestor_context` (hierarchical embeddings); a
  `content_hash` lets the indexer skip unchanged blocks. Nearest-neighbour search
  is cosine distance over a pgvector HNSW index, with optional `block_type`
  faceting — reusing the same embedder/vector machinery as document-level search
  (`docs/semantic-search-plan.md`).
  """
  use Ash.Resource,
    domain: KilnCMS.SearchIndex,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @block_types [:heading, :image, :rich_text, :quote, :embed, :divider, :custom]

  postgres do
    table "block_embeddings"
    repo KilnCMS.Repo

    custom_indexes do
      # HNSW (cosine) index for approximate nearest-neighbour over block vectors.
      # `all_tenants?: true` keeps `org_id` out of the index (epic #336) — HNSW
      # can't be multicolumn; the tenant filter rides the query's `WHERE org_id`.
      index ["embedding vector_cosine_ops"],
        name: "block_embeddings_hnsw_index",
        using: "hnsw",
        all_tenants?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_document do
      argument :document_type, :atom, allow_nil?: false
      argument :document_id, :uuid, allow_nil?: false
      filter expr(document_type == ^arg(:document_type) and document_id == ^arg(:document_id))
    end

    create :upsert do
      upsert? true
      upsert_identity :doc_block

      accept [
        :document_type,
        :document_id,
        :block_key,
        :block_type,
        :content_hash,
        :ancestor_context,
        :embedding,
        :embedded_at
      ]
    end

    # Block-granular nearest-neighbour, with optional block_type faceting (D16).
    read :nearest do
      argument :query, :string, allow_nil?: false
      argument :block_type, :atom
      argument :limit, :integer, default: 10

      filter expr(not is_nil(^ref(:embedding)))
      filter expr(is_nil(^arg(:block_type)) or ^ref(:block_type) == ^arg(:block_type))

      prepare fn query, _context ->
        with true <- KilnCMS.Search.semantic?(),
             {:ok, vector} <- KilnCMS.Search.embed(Ash.Query.get_argument(query, :query)) do
          query
          |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
          |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
        else
          _ -> Ash.Query.limit(query, 0)
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): block embeddings are partitioned by org so
  # per-block retrieval stays per-site — one shared HNSW index, filtered by
  # `org_id` (the whole reason `:attribute` was chosen over schema-per-tenant).
  # `global?: true` keeps the tenant optional for the current tenant-less
  # indexer; the `:doc_block` unique index gains `org_id` automatically.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # Owning organization (epic #336). Set from tenant/default; never accepted
    # from input (absent from the `:upsert` accept list).
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :document_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:page, :post]],
      public?: true

    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :block_key, :string, allow_nil?: false, public?: true

    attribute :block_type, :atom,
      allow_nil?: false,
      constraints: [one_of: @block_types],
      public?: true

    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :ancestor_context, :string, public?: true
    attribute :embedding, KilnCMS.Search.Vector, public?: true
    attribute :embedded_at, :utc_datetime_usec, public?: true
  end

  relationships do
    # FK to the owning org (epic #336); the tenant axis is the `org_id` attribute.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  calculations do
    # pgvector cosine distance (`<=>`) between a block's embedding and the query.
    calculate :semantic_distance,
              :float,
              expr(fragment("? <=> ?::vector", ^ref(:embedding), ^arg(:query_vector))) do
      argument :query_vector, KilnCMS.Search.Vector, allow_nil?: false
    end
  end

  identities do
    identity :doc_block, [:document_type, :document_id, :block_key]
  end
end
