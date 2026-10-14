defmodule KilnCMS.Search.DocumentChunkEmbedding do
  @moduledoc """
  One vector over a slice of a document's `search_text` that lies **past** the
  embedder's window (#1940).

  A document's own `embedding` is one vector over `search_text`, which the
  model truncates at its window — 512 tokens for every model Kiln supports.
  Since #1585 searchable custom fields extend `search_text`, so prose-heavy
  records routinely run past it, and text beyond the window was invisible to
  the semantic leg and to the relevance floor. With `chunk_long_documents` on
  (`KilnCMS.Search.chunk_long_documents?/0`), `KilnCMS.Search.DocumentChunkIndexer`
  embeds that remainder as overlapping windows (`KilnCMS.Search.Chunker`) and
  stores one row per window here; the block leg of `KilnCMS.Search.hybrid/3`
  then reaches a document through its nearest chunk as well as its nearest
  block, and the floor judges it by the nearer of all its distances.

  ## Why its own table, not rows in `block_embeddings`

  #1940 offered both. A synthetic block id would have put rows that are not
  blocks into a table whose every consumer reads them *as* blocks:
  `KilnCMS.Search.BlockSearch` returns block rows ("find the relevant
  section") with a `block_type` and an `ancestor_context`; `Search.Related`'s
  similar-content and near-duplicate paths, and `KilnCMS.Search.DocumentCentroids`
  (the `KilnCMS.Organize` clustering), average **every** stored row of a
  document into its centroid, so a chunk would weigh the late half of a long
  record twice; `BlockIndexer.prune_stale` diffs a document's stored keys
  against its live block keys and would delete every synthetic row on the next
  fire. Each would need a filter, and the next consumer would not know it
  needed one. Block rows are also written by *firing* (published content
  only), while chunks follow the document vector, drafts included — the same
  table would have mixed two visibility regimes with no column to tell them
  apart. A separate table costs one more HNSW index and keeps each consumer's
  contract as it was.

  ## What a row holds

  An index row, not text: the document it belongs to, its position past the
  window (`chunk_index`, 0 first), the vector, and a `content_hash` of exactly
  what was embedded (`DocumentChunkIndexer` reuses a vector whose hash still
  matches instead of paying the inference again). Unlike `block_embeddings`
  there is no `ancestor_context` — nothing here can leak a draft's words — but
  the read policy is the same editor-and-system one all the same: a vector is
  derived from the text, and nothing caller-facing reads this table.

  ## No foreign key to the document

  `document_id` points into whichever content table `document_type` names —
  `pages`, `posts`, `entries`, or a generated type's own table — so no single
  FK can cascade, which is why `block_embeddings` has none either. Rows are
  removed by the paths that remove the document's vector: a re-embed replaces
  them (a shorter document leaves none), a passphrase lock clears them
  (`EmbeddingWorker`), and the hard `:purge` destroys them
  (`KilnCMS.CMS.Changes.DeleteChunkEmbeddings`). A soft delete keeps them, as
  it keeps the document's own `embedding`: trash can be restored, and the
  block leg reads documents through the caller's own read, which never
  returns an archived one.
  """
  use Ash.Resource,
    domain: KilnCMS.SearchIndex,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_chunk_embeddings"
    repo KilnCMS.Repo

    custom_indexes do
      # HNSW (cosine) index for approximate nearest-neighbour over chunk
      # vectors — the block leg's ORDER BY. Same shape as
      # `block_embeddings_hnsw_index`: `all_tenants?: true` keeps `org_id` out
      # of the index (HNSW cannot be multicolumn), and the tenant filter rides
      # the query's `WHERE org_id` — which is a filtered scan, so recall leans
      # on `hnsw.iterative_scan = strict_order` (`KilnCMS.Repo`, #998).
      index ["embedding vector_cosine_ops"],
        name: "document_chunk_embeddings_hnsw_index",
        using: "hnsw",
        all_tenants?: true

      # Point lookup for the `for_document` read — the replace and the purge
      # both seek one document's rows. `org_id`-free for the reason the block
      # table's twin is: the identity leads with `org_id`.
      index [:document_type, :document_id],
        name: "document_chunk_embeddings_doc_lookup_index",
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

    create :create do
      primary? true

      accept [
        :document_type,
        :document_id,
        :chunk_index,
        :content_hash,
        :embedding,
        :embedded_at
      ]
    end

    # Nearest chunks of an already-computed query vector, for the block leg
    # of `KilnCMS.Search.hybrid/3` — one content type's chunks, as every leg
    # runs per type. Nearest first; a document with several chunks near the
    # query appears once per chunk, and the leg keeps its nearest.
    read :nearest_to_vector do
      argument :vector, {:array, :float}, allow_nil?: false
      argument :document_type, :atom
      argument :limit, :integer, default: 20

      filter expr(not is_nil(^ref(:embedding)))
      filter expr(is_nil(^arg(:document_type)) or ^ref(:document_type) == ^arg(:document_type))

      prepare fn query, _context ->
        if KilnCMS.Search.semantic?() do
          vector = Ash.Query.get_argument(query, :vector)

          query
          |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
          |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
        else
          Ash.Query.limit(query, 0)
        end
      end
    end
  end

  policies do
    # The same two readers as `KilnCMS.Search.BlockEmbedding`: the search
    # system actor (the indexer and the block leg) and editors and up. Rows
    # carry no text, but a vector is derived from text — drafts included —
    # and no caller-facing path reads this table, so it opens no wider than
    # its sibling. Whether the CALLER may see a document a chunk points at is
    # decided by reading the document under the caller's own authorization
    # (`KilnCMS.Search.hybrid/3`'s block leg).
    policy action_type(:read) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :search}
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # `DocumentChunkIndexer` and the purge change are the only writers.
    # `authorize_if` rather than `bypass`, so a policy added here later
    # applies to them too (#1402).
    policy action_type([:create, :update, :destroy]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :search}
      forbid_if always()
    end
  end

  # Partitioned by org exactly as `block_embeddings` is (epic #336): one
  # shared HNSW index, filtered by `org_id`. The identity gains `org_id`
  # automatically.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # Owning organization (epic #336). Set from the tenant; never accepted
    # from input (absent from the `:create` accept list).
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # `KilnCMS.CMS.ContentTypes.type_atom/1` of the document's resource — the
    # key the block leg filters on. Unconstrained, unlike
    # `BlockEmbedding.document_type`: chunks follow the document vector, which
    # every content resource writes, generated types included, so the set is
    # the content registry's and not a list this file could keep.
    attribute :document_type, :atom, allow_nil?: false, public?: true
    attribute :document_id, :uuid, allow_nil?: false, public?: true

    # 0 is the first window past the one the document's own vector covers.
    attribute :chunk_index, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    # SHA-256 (hex) of exactly what was embedded — see the moduledoc.
    attribute :content_hash, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 64]

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
    # pgvector cosine distance (`<=>`) between a chunk's embedding and the query.
    calculate :semantic_distance,
              :float,
              expr(fragment("? <=> ?::vector", ^ref(:embedding), ^arg(:query_vector))) do
      argument :query_vector, KilnCMS.Search.Vector, allow_nil?: false
    end
  end

  identities do
    identity :doc_chunk, [:document_type, :document_id, :chunk_index]
  end
end
