defmodule KilnCMS.CMS.Menu do
  @moduledoc """
  A named, editor-managed **navigation menu** — an ordered tree of
  `KilnCMS.CMS.MenuItem`s (#466).

  Kiln had no navigation resource at all: categories are flat, and every
  headless front end consuming Kiln had to hard-code its nav. A menu is the
  Drupal-core analogue — "Main navigation", "Footer" — addressed by a stable
  `key` so a front end can ask for `main` without knowing an id.

  ## Localization

  A menu is **per locale**, exactly like content: variants share a `key` and
  differ by `locale` (`unique [key, locale]`), so `/api/menus/main?locale=fr`
  returns French labels and French destinations. This is deliberately the same
  shape as the one-record-per-locale content model rather than a per-item
  translations map — labels, ordering *and* which items exist all differ
  between locales in practice ("Impressum" has no English sibling), and a map
  can only translate the first of those.

  A missing locale variant is a miss, not a fallback: silently serving English
  nav on a French page is worse than serving none, and the delivery layer's
  caller can decide.

  ## Authoring vs delivery

  Menus are structure, not content: no workflow, no version history, no
  soft-delete — the same lightweight treatment `Category` and `TagGroup` get.
  Editors manage them at `/editor/menus`; delivery resolves them through
  `KilnCMS.CMS.Menus`, which is where the published-visibility rules live (an
  item pointing at unpublished content is omitted for an anonymous reader).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource],
    # The primary `:read` carries a default sort so every caller lists menus in
    # the same order without repeating it.
    primary_read_warning?: false

  # No auto JSON:API/GraphQL surface, deliberately. The stored rows carry
  # references and no URLs, and — more importantly — they carry items an editor
  # has hidden and items pointing at unpublished content. Exposing them raw
  # would serve anonymously exactly what `KilnCMS.CMS.Menus` exists to omit: the
  # label and target id of an unannounced page. Delivery is
  # `GET /api/menus/:key` and the `menu` GraphQL query, both of which resolve.

  admin do
    resource_group :taxonomy
    table_columns [:name, :key, :locale, :inserted_at]
    relationship_display_fields [:name]
    label_field :name
  end

  postgres do
    table "menus"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:destroy]
    default_accept [:key, :name, :locale, :description]

    create :create, primary?: true
    update :update, primary?: true

    read :read do
      primary? true
      prepare build(sort: [name: :asc, locale: :asc])
    end

    # Delivery: one menu by its stable key + locale. `get?` so a miss is a
    # `nil`/not-found rather than a list — a front end asking for "main" wants
    # one menu or nothing.
    read :by_key do
      get? true
      argument :key, :string, allow_nil?: false
      argument :locale, :string, allow_nil?: false
      filter expr(key == ^arg(:key) and locale == ^arg(:locale))
    end
  end

  policies do
    # Read-scoped API keys can never write structure, and no key may hard-delete
    # it — before the admin bypass so a key on an admin account can't skip it
    # (mirrors the taxonomy policies).
    policy action_type([:create, :update]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    policy action_type(:destroy) do
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if always()
    end

    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # World-readable: navigation is rendered on every public page, and a
    # headless front end fetches it anonymously. What an item *points at* is
    # still gated — see `KilnCMS.CMS.Menus`.
    policy action_type(:read) do
      authorize_if always()
    end

    # Editors manage menus; admins too, via the bypass.
    policy action_type([:create, :update]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Hard deletes are admin-only (allowed by the bypass above).
    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  # Multi-tenancy (epic #336): a menu belongs to one site. `global?: true` keeps
  # the tenant optional so tenant-less callers (seeds, single-org delivery) keep
  # working and land in the default org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped
    # create, else the sole org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The stable machine name a front end addresses ("main", "footer"). Shared
    # across locale variants — that is what pairs them.
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :locale, :string, allow_nil?: false, default: "en", public?: true
    attribute :description, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :items, KilnCMS.CMS.MenuItem do
      destination_attribute :menu_id
      public? true
    end
  end

  identities do
    identity :unique_key, [:key, :locale]
  end
end
