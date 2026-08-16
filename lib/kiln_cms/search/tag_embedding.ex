defmodule KilnCMS.Search.TagEmbedding do
  @moduledoc """
  The persisted embedding of a tag's **name** (#1085), so
  `KilnCMS.Search.Related.suggest_tags/2` is one indexed pgvector query rather
  than one vector lookup and one 384-element cosine computation per tag per
  call.

  ## Why persist rather than cache

  A tag's name is stable and its vector is a pure function of it, so the
  embedding is write-once per tag — not per panel open, and not per node.
  `KilnCMS.Search.VectorCache` already memoized the vector per name (#964),
  which stopped the *inference* being repeated; it did not stop the work: the
  #851 relevance ceiling filtered *after* every unapplied tag had been fetched
  from ETS and scored in the BEAM, so a 500-tag org paid 500 lookups and 500
  dot products per call and could then legitimately return `[]` having done
  all of it. With the vector in a column, the ceiling becomes a `WHERE` on
  `<=>` and the ranking an `ORDER BY ... LIMIT n` — the shape
  `BlockEmbedding.nearest_to_vector` already has for blocks.

  ## Freshness is the stored name, not a timestamp

  `name` is the string the vector was computed for. A caller compares it to
  the tag's current name and re-embeds on mismatch, so a rename cannot keep
  serving the old vector and nothing has to hook the tag's write path. Rows
  are filled **lazily by the first `suggest_tags/2` call** that needs them
  (which is also where the `KilnCMS.LLM.Budget` charge for the inference
  lives, #1076), so turning semantic search on backfills a taxonomy on first
  use rather than needing a migration task; deleting the tag cascades the row.

  ## No HNSW index, deliberately

  A taxonomy is hundreds of rows per org, not millions of blocks. An exact
  scan over `org_id`'s rows with `<=>` costs microseconds, and it sidesteps
  the pgvector post-filter trap `#998` documents for the block index — HNSW
  returns its `k` nearest over the *whole* index and only then applies
  `WHERE org_id = …`, so a small tenant beside a large one could get zero rows
  back. Exact is both faster and correct here.
  """
  use Ash.Resource,
    domain: KilnCMS.SearchIndex,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "tag_embeddings"
    repo KilnCMS.Repo

    references do
      # A deleted tag takes its vector with it — no reaper needed.
      reference :tag, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    # Every stored row for a set of tags — `{tag_id, name}` is what a caller
    # needs to decide which are missing or stale before it ranks.
    read :for_tags do
      argument :tag_ids, {:array, :uuid}, allow_nil?: false
      filter expr(tag_id in ^arg(:tag_ids))
    end

    create :upsert do
      upsert? true
      upsert_identity :one_per_tag
      accept [:tag_id, :name, :embedding, :embedded_at]
    end

    # The tags among `:tag_ids` whose stored vector sits within `:threshold`
    # cosine distance of `:vector`, nearest first, at most `:limit`. Ceiling and
    # ranking are both in the query — the whole point of the table (#1085).
    # `:tag_ids` rather than "everything but the applied ones" so the caller's
    # *authorized* candidate list is the universe: a tag the actor may not read
    # is not in it and so cannot be suggested. Empty when semantic search is
    # off, like the block reads.
    read :nearest_to_vector do
      argument :vector, {:array, :float}, allow_nil?: false
      argument :tag_ids, {:array, :uuid}, allow_nil?: false
      argument :threshold, :float, allow_nil?: false
      argument :limit, :integer, default: 5

      filter expr(not is_nil(^ref(:embedding)) and tag_id in ^arg(:tag_ids))

      prepare fn query, _context ->
        if KilnCMS.Search.semantic?() do
          vector = Ash.Query.get_argument(query, :vector)
          threshold = Ash.Query.get_argument(query, :threshold)

          query
          |> Ash.Query.filter(semantic_distance(query_vector: ^vector) <= ^threshold)
          |> Ash.Query.sort([{:semantic_distance, {%{query_vector: vector}, :asc}}])
          |> Ash.Query.load(semantic_distance: %{query_vector: vector})
          |> Ash.Query.limit(Ash.Query.get_argument(query, :limit))
        else
          Ash.Query.limit(query, 0)
        end
      end
    end
  end

  policies do
    # A tag name is world-readable on the tag itself, but this table is only
    # ever read by `Search.Related` as the system; keep it off the API surface
    # the same way `BlockEmbedding` is.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The name the vector was computed for — the freshness check (moduledoc).
    # Same ceiling as `Tag.name` itself (`KilnCMS.CMS.Taxonomy`): this column
    # only ever holds a copy of an already-bounded tag name, never independent
    # user input.
    attribute :name, :string, allow_nil?: false, public?: true do
      constraints max_length: KilnCMS.Limits.line()
    end
    attribute :embedding, KilnCMS.Search.Vector, public?: true
    attribute :embedded_at, :utc_datetime_usec, public?: true
  end

  relationships do
    belongs_to :tag, KilnCMS.CMS.Tag do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  calculations do
    calculate :semantic_distance,
              :float,
              expr(fragment("? <=> ?::vector", ^ref(:embedding), ^arg(:query_vector))) do
      argument :query_vector, KilnCMS.Search.Vector, allow_nil?: false
    end
  end

  identities do
    identity :one_per_tag, [:tag_id]
  end
end
