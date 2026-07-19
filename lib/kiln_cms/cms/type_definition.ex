defmodule KilnCMS.CMS.TypeDefinition do
  @moduledoc """
  An **admin-defined (dynamic) content type** — a row, not a module (decision
  D17 in `docs/dynamic-content-types-plan.md`).

  Compiled content types (`use KilnCMS.CMS.Content`) stay the strongly-modeled
  tier; a TypeDefinition is the Directus-style tier: an admin names a type
  ("Recipe"), attaches `FieldDefinition` rows to it, and entries are stored in
  the shared generic entry table. Dynamic type names are **strings end-to-end**
  — nothing here creates atoms or modules at runtime.

  `name` is the permanent machine key (it keys entries, URLs, and fired
  artifacts), so it is create-only. Types are soft-deleted (AshArchival): an
  archived type stops resolving publicly but its entries remain editable and
  exportable, and a restore brings it back intact — which is also why `name`
  and `path_segment` stay unique (per site — epic #336) across archived rows.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshArchival.Resource, AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:name, :label, :path_segment, :inserted_at]
    relationship_display_fields [:label]
    label_field :label
  end

  postgres do
    table "type_definitions"
    repo KilnCMS.Repo
  end

  archive do
    exclude_read_actions([:archived])
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :name,
        :label,
        :plural_label,
        :path_segment,
        :has_excerpt,
        :has_published_feed,
        :icon,
        :description
      ]

      change KilnCMS.CMS.Changes.DefaultPathSegment
    end

    # `name` is deliberately not updatable — it keys entries, delivery URLs and
    # fired artifacts. Everything presentational is.
    update :update do
      primary? true
      require_atomic? false

      accept [
        :label,
        :plural_label,
        :path_segment,
        :has_excerpt,
        :has_published_feed,
        :icon,
        :description
      ]
    end

    # Soft-delete (AshArchival): the type disappears from the registry but its
    # entries and history survive; `:restore` undoes it. Non-atomic so the
    # registry cache-bust after_action can run.
    destroy :destroy do
      primary? true
      require_atomic? false
    end

    update :restore do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, nil)
    end

    # Archived ("trashed") type definitions — the only read that sees them.
    read :archived do
      filter expr(not is_nil(archived_at))
    end

    read :by_name do
      get? true
      argument :name, :string, allow_nil?: false
      filter expr(name == ^arg(:name))
    end
  end

  policies do
    # Admins own the schema — defining content types is an admin act, exactly
    # like defining custom fields.
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Editors may read definitions so the editor UI can list dynamic types.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  # Every write reshapes the public type registry — drop its cache (and the
  # sitemap's) so delivery picks the change up immediately.
  changes do
    change KilnCMS.CMS.Changes.BustTypeRegistry, on: [:create, :update, :destroy]
  end

  validations do
    # `name` is the machine key (map keys, artifact type, promotion module
    # name), same charset rule as FieldDefinition names.
    validate match(:name, ~r/\A[a-z][a-z0-9_]*\z/) do
      message "must be lowercase letters, digits and underscores, starting with a letter"
    end

    # `path_segment` becomes the first public URL segment (`/<segment>/<slug>`).
    validate match(:path_segment, ~r/\A[a-z][a-z0-9_-]*\z/) do
      where present(:path_segment)
      message "must be lowercase letters, digits, underscores and hyphens"
    end

    validate present(:label)

    # No collisions with compiled content types, reserved router segments, or
    # configured locales (dynamic-vs-dynamic uniqueness is the identities below).
    validate KilnCMS.CMS.Validations.AvailableTypeName
  end

  # Multi-tenancy (epic #336): a dynamic content type belongs to one site, so its
  # name/path_segment are unique **per org** (two sites can each define "recipe").
  # `global?: true` keeps the tenant optional: tenant-less reads/writes (the
  # single-org rollout, seeds) land in the default org via the `org_id` default.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create,
    # else the default org; never accepted from input (`writable?: false`, absent
    # from `accept`) — the cross-site boundary.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Permanent machine key, e.g. "recipe". Create-only (see `:update`).
    attribute :name, :string, allow_nil?: false, public?: true

    # Human names for the editor UI and admin nav.
    attribute :label, :string, allow_nil?: false, public?: true
    attribute :plural_label, :string, public?: true

    # First URL segment for public delivery. Defaults to `"#{name}s"` on create
    # (see `Changes.DefaultPathSegment`).
    attribute :path_segment, :string, allow_nil?: false, public?: true

    # Mirror the Content macro's `:excerpt?` / `:published?` options.
    attribute :has_excerpt, :boolean, allow_nil?: false, default: false, public?: true
    attribute :has_published_feed, :boolean, allow_nil?: false, default: false, public?: true

    # Admin-nav niceties.
    attribute :icon, :string, public?: true
    attribute :description, :string, public?: true

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

    # The dynamic type's schema: admin-defined fields, rendered by the editor
    # and enforced on write by `Changes.ApplyCustomFields`.
    has_many :field_definitions, KilnCMS.CMS.FieldDefinition do
      destination_attribute :type_definition_id
      sort position: :asc, name: :asc
    end
  end

  identities do
    # Unique **per org** (Ash prepends `org_id`) — including archived rows, so
    # restoring a type can never collide with a later re-creation of the same
    # name within the same site.
    identity :unique_name, [:name]
    identity :unique_path_segment, [:path_segment]
  end
end
