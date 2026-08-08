defmodule KilnCMS.CMS.FeedSettings do
  @moduledoc """
  Per-org syndication policy (#719): which content types appear in this site's
  feeds, and which of them carry their rendered body rather than a summary.

  Both used to be `config :kiln_cms, :feeds` only, which is the wrong grain for
  a multi-tenant install — `full_content` in particular has a real disclosure
  consequence, and the switch lived in a file a tenant admin cannot edit. This
  row is the per-org layer above that config; see `KilnCMS.Feeds` for how the
  two resolve.

  One row per organization — the `KilnCMS.CMS.FormSpamSettings` shape: admin-only
  settings with no `paper_trail` history and no public read policy (the delivery
  path reads it as a system read, cached, exactly as `KilnCMS.Branding` does).
  The row is created lazily by `:save`, never by a read, so a site that never
  touches the page costs nothing.

  ## Why both columns are nullable

  `nil` means *"inherit the operator default"*; `[]` means *"the admin said none"*.
  Collapsing the two would make an admin who clears the full-content list fall
  back to a config that turns it on for everyone — the exact inversion this
  issue exists to remove. `/editor/feeds` writes explicit lists on save and drops
  the whole row on "reset", which is how an admin gets back to `nil`.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # A ceiling on how many type names one list may carry. Comfortably above any
  # real site's type count, and there only so a settings row can never make a
  # per-request `not in` scan unbounded.
  @max_types 1_000

  admin do
    resource_group :content
    table_columns [:excluded_types, :full_content_types, :updated_at]
  end

  postgres do
    table "feed_settings"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:excluded_types, :full_content_types]

    # On a conflict AshPostgres narrows `upsert_fields` to the attributes the
    # changeset actually carries, so omitting one column leaves it alone rather
    # than nulling it — which is what makes a partial
    # `save_feed_settings(%{full_content_types: […]})` safe. That narrowing is
    # computed across a whole *batch*, so a bulk upsert mixing rows that set
    # different columns would write NULL into the one a given row omitted, and a
    # NULL here does not mean "unchanged", it means "inherit the operator
    # config" — the inversion #719 exists to remove. Write these one row at a
    # time, which is all `/editor/feeds` and the code interface ever do.
    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:excluded_types, :full_content_types]

      change KilnCMS.CMS.Changes.BustFeedSettings
    end

    update :update do
      primary? true
      require_atomic? false

      change KilnCMS.CMS.Changes.BustFeedSettings
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change KilnCMS.CMS.Changes.BustFeedSettings
    end
  end

  policies do
    # Never delivered as a document the way branding is: the resolved policy
    # reaches the delivery path through `KilnCMS.Feeds`, which reads it as a
    # system read. So no public read here.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

    # Content-type **names** (`"post"`, `"page"`, a dynamic type's own name), the
    # same spelling `config :kiln_cms, :feeds` uses and the one `ContentTypes`
    # descriptors carry. Names rather than ids because compiled types have no
    # row to point at, and a name that no longer resolves is inert rather than a
    # dangling reference.
    #
    # Bounded like `FormSpamSettings`' keyword list: a settings value must never
    # be able to make a per-request filter unbounded. The bounds are sized to
    # what a content type can actually be, not picked round: a name is a
    # `TypeDefinition.name` (or a compiled type's), so it is held to
    # `KilnCMS.Limits.line()` there and a tighter cap here would make a legally
    # created type impossible to exclude — the save would fail with a length
    # error naming a constraint no admin can see, on every subsequent visit to
    # the page. The list bound is `@max_types` for the same reason: exclusions
    # are derived by subtraction over *every* type a site has.
    attribute :excluded_types, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: @max_types, items: [max_length: KilnCMS.Limits.line()]
    end

    attribute :full_content_types, {:array, :string} do
      allow_nil? true
      public? true
      constraints max_length: @max_types, items: [max_length: KilnCMS.Limits.line()]
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :one_per_org, [:org_id]
  end
end
