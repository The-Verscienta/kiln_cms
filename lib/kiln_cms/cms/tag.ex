defmodule KilnCMS.CMS.Tag do
  @moduledoc """
  A content tag — taxonomy with a **many-to-many** relationship to content: a
  `Page`/`Post` can carry many tags and a tag applies to many pages/posts,
  linked through the `PageTag`/`PostTag` join resources.

  Like `Category`, tags are a lightweight, editor-managed, world-readable
  lookup resource (no versioning/workflow/soft-delete).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshGraphql.Resource, AshAdmin.Resource]

  graphql do
    type :tag

    # Taxonomy is world-readable (D7) — list all tags and fetch one by slug for
    # headless frontends building tag clouds / filtered listings.
    queries do
      list :tags, :read do
        paginate_with nil
      end

      get :tag_by_slug, :by_slug do
        identity false
      end
    end
  end

  json_api do
    type "tag"

    # JSON:API parity with the GraphQL taxonomy surface (#185): list, fetch by
    # slug, and fetch by id. Taxonomy is world-readable (D7).
    routes do
      base "/tags"
      index :read
      get :by_slug, route: "/by-slug/:slug"
      # `/:id` last so it can't shadow the static sub-path above.
      get :read
    end
  end

  # AshAdmin: group taxonomy together and label tags by name (issue #25).
  admin do
    resource_group :taxonomy
    table_columns [:name, :slug, :inserted_at]
    relationship_display_fields [:name]
    label_field :name
  end

  postgres do
    table "tags"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :slug]

    create :create, primary?: true
    update :update, primary?: true

    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
    end

    # Taxonomy leg of global search: name matched by substring or trigram word
    # similarity (typo-tolerant, same operator as content autocomplete).
    # Closest names first, capped — tags are a small lookup table, so no
    # trigram index is needed.
    read :search do
      argument :query, :string, allow_nil?: false

      filter expr(
               fragment("? ILIKE '%' || ? || '%'", name, ^arg(:query)) or
                 fragment("? <% ?", ^arg(:query), name)
             )

      prepare fn query, _context ->
        q = Ash.Query.get_argument(query, :query)

        query
        |> Ash.Query.sort([{:name_similarity, {%{query: q}, :desc}}])
        |> Ash.Query.limit(10)
      end
    end
  end

  policies do
    # Read-scoped API keys can never write taxonomy, and no key may hard-delete
    # it — before the admin bypass so a key on an admin account can't skip it
    # (mirrors the content policy; see Checks.ApiKeyWithoutWriteAccess).
    policy action_type([:create, :update]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    policy action_type(:destroy) do
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    # Many-to-many inverse of each content type's `tags`, through the shared
    # polymorphic `Tagging` join (one table for all content types). Joining on
    # `subject_id` returns only records of the destination type, since ids are
    # globally unique.
    many_to_many :pages, KilnCMS.CMS.Page do
      through KilnCMS.CMS.Tagging
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :subject_id
      public? true
    end

    many_to_many :posts, KilnCMS.CMS.Post do
      through KilnCMS.CMS.Tagging
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :subject_id
      public? true
    end
  end

  calculations do
    # Trigram closeness (0–1) of a search query to the tag name — orders
    # `:search`. Internal (sorting only).
    calculate :name_similarity,
              :float,
              expr(fragment("word_similarity(?, ?)", ^arg(:query), name)) do
      argument :query, :string, allow_nil?: false
    end
  end

  aggregates do
    # Usage counts for the taxonomy management UI (and public APIs).
    count :page_count, :pages do
      public? true
    end

    count :post_count, :posts do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
