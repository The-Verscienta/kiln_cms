defmodule KilnCMS.CMS.TagGroup do
  @moduledoc """
  A named bucket of `Tag`s — the organizing layer above tags themselves.

  Tags are a flat many-to-many vocabulary, which stops scaling once a site has
  more than a couple dozen of them: the editor's tag picker becomes an
  undifferentiated wall of checkboxes. A tag group gives that wall structure —
  the picker renders one section per group, alphabetized within it.

  A tag belongs to at most one group (`Tag.tag_group_id`, nullable); tags
  without one are shown under "Ungrouped".

  Groups may be scoped to specific content types via `content_types`, so a
  site can offer a different tag vocabulary per type ("Post themes" on posts
  only). An **empty** list means the group applies everywhere — the same
  empty-means-unrestricted convention the RBAC type scopes use (see
  `KilnCMS.Accounts.Scoping`), and for the same reason: the list is tiny and
  matched in Elixir, never in SQL.

  Like `Category` and `Tag`, this is a lightweight, editor-managed,
  world-readable lookup resource (no versioning/workflow/soft-delete).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshGraphql.Resource, AshAdmin.Resource],
    # The primary :read carries only a default sort, so every caller (the
    # picker, the taxonomy manager, REST/GraphQL) gets groups in picker order
    # without repeating it. Internal uses (relationship loads, policy checks)
    # are unaffected by an ORDER BY.
    primary_read_warning?: false

  graphql do
    type :tag_group

    # Taxonomy is world-readable (D7) — list all groups and fetch one by slug so
    # headless frontends can render the same grouped tag UI Kiln's editor does.
    queries do
      list :tag_groups, :read do
        paginate_with nil
      end

      get :tag_group_by_slug, :by_slug do
        identity false
      end
    end
  end

  json_api do
    # snake_case `type`, kebab-case route base — the convention media_item sets.
    type "tag_group"
    includes [:tags]

    # JSON:API parity with the GraphQL taxonomy surface (#185): list, fetch by
    # slug, and fetch by id. Taxonomy is world-readable (D7).
    routes do
      base "/tag-groups"
      index :read
      get :by_slug, route: "/by-slug/:slug"
      # `/:id` last so it can't shadow the static sub-path above.
      get :read
    end
  end

  # AshAdmin: group taxonomy together and label groups by name (issue #25).
  admin do
    resource_group :taxonomy
    table_columns [:name, :slug, :position, :inserted_at]
    relationship_display_fields [:name]
    label_field :name
  end

  postgres do
    table "tag_groups"
    repo KilnCMS.Repo

    # `:unique_slug` is the `org_id`-LEADING `(org_id, slug)` composite, which
    # Postgres can't seek for a tenant-less `by_slug` delivery read (reads set no
    # tenant under `global?: true`). This `all_tenants?: true` companion keeps a
    # plain `(slug)` index so those lookups still seek; redundant with the
    # composite once every taxonomy read threads the tenant (mirrors tag.ex).
    custom_indexes do
      index [:slug], name: "tag_groups_slug_lookup_index", all_tenants?: true
    end
  end

  actions do
    defaults [:destroy]
    default_accept [:name, :slug, :description, :position, :content_types]

    create :create, primary?: true

    # `require_atomic? false`: `KnownContentTypes` resolves each entry against the
    # (per-org, DB-backed) type registry, which can't run inside an atomic UPDATE.
    update :update do
      primary? true
      require_atomic? false
    end

    # Picker order: the editor-chosen `position` first, name as the tiebreaker,
    # so an unordered set of groups still reads alphabetically.
    read :read do
      primary? true
      prepare build(sort: [position: :asc, name: :asc])
    end

    # Public delivery: fetch a single group by its slug (taxonomy is public).
    read :by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
    end
  end

  policies do
    # Read-scoped API keys can never write taxonomy, and no key may hard-delete
    # it — before the admin bypass so a key on an admin account can't skip it
    # (mirrors the tag policy; see Checks.ApiKeyWithoutWriteAccess).
    policy action_type([:create, :update]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    policy action_type(:destroy) do
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if always()
    end

    # Admins may do anything.
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Taxonomy is world-readable — groups are referenced by published content's
    # tags and served to public/headless frontends.
    policy action_type(:read) do
      authorize_if always()
    end

    # Managing taxonomy is reserved for editors (and admins via the bypass).
    policy action_type([:create, :update]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Hard deletes are admin-only (allowed by the bypass; denied here for all
    # other roles). Deleting a group never deletes its tags — the FK on
    # `tags.tag_group_id` nilifies, so they fall back to "Ungrouped".
    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  validations do
    # `content_types` is in `default_accept`, so without this every non-LiveView
    # write path (AshAdmin, seeds, code interfaces) could file a group under a
    # content type that doesn't exist — a UI checkbox is not a data-level guard
    # (#526). Only on writes; a stale entry on an existing row is not re-checked
    # on read.
    validate {KilnCMS.CMS.Validations.KnownContentTypes, []}, on: [:create, :update]
  end

  # Multi-tenancy (epic #336): taxonomy is per-site, partitioned by `org_id`
  # (Ash `:attribute` strategy — same axis as content). `global?: true` keeps a
  # tenant OPTIONAL: tenant-less reads/writes (editor, seeds, public delivery)
  # keep working and land in the default org (see the `org_id` default).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set automatically from the tenant on a
    # scoped create, else defaults to the sole org; never accepted from input
    # (`writable?: false`, absent from `default_accept`) — the cross-site boundary.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # Manual ordering of the picker's sections; ties break on name.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Content types this group applies to, as public type-name strings
    # (`"page"`, `"post"`, or a dynamic `TypeDefinition`'s name — the same
    # currency `KilnCMS.CMS.ContentTypes.type_name/1` speaks, so compiled and
    # admin-defined types are addressed uniformly).
    #
    # EMPTY MEANS EVERY TYPE, not "no types" — a group is unrestricted until an
    # editor narrows it. Matched in Elixir at the call site (the list is tiny),
    # mirroring `KilnCMS.Accounts.Scoping.permitted?/4`.
    attribute :content_types, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :tags, KilnCMS.CMS.Tag do
      public? true
    end
  end

  aggregates do
    # Usage count for the taxonomy management UI (and public APIs).
    count :tag_count, :tags do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
