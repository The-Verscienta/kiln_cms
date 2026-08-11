defmodule KilnCMS.CMS.MenuItem do
  @moduledoc """
  One entry in a `KilnCMS.CMS.Menu` — a label, a destination, and a place in
  the tree (#466).

  ## Destinations

  `link_type` decides what the item points at:

    * `:content` — a **reference** to a content record (`target_type` +
      `target_id`, the same currency `KilnCMS.CMS.Redirect` and
      `KilnCMS.CMS.ContentLink` speak). The URL is computed at read time from
      the record's *current* published path, so renaming a slug never breaks
      navigation and never leaves a stale link behind. This is the whole reason
      the reference is stored rather than a frozen path.
    * `:url` — an external or hand-written destination. Passed through
      `KilnCMS.HtmlSanitizer.safe_href/1` on write, so a `javascript:` label
      trap can't be stored, let alone rendered by a front end that trusts the
      API.
    * `:none` — a heading with no link (a section label in a mega-menu).

  ## Tree

  `parent_id` is a self-reference and `position` orders siblings. Depth is
  capped (`max_depth/0`) and a cycle is refused outright: this tree is walked
  by anonymous delivery on every page render, so "it terminates" has to be a
  schema property, not a convention.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource],
    primary_read_warning?: false

  # How deep a menu may nest. Three levels covers every real navigation
  # (section → group → link); beyond that a menu is a sitemap. The bound also
  # makes the delivery walk trivially terminating.
  @max_depth 3

  @doc "Deepest nesting level a menu item may sit at (root items are depth 1)."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  admin do
    resource_group :taxonomy
    table_columns [:label, :link_type, :position]
    relationship_display_fields [:label]
    label_field :label
  end

  postgres do
    table "menu_items"
    repo KilnCMS.Repo

    references do
      # Deleting a menu takes its items; deleting an item takes its subtree.
      reference :menu, on_delete: :delete
      reference :parent, on_delete: :delete
    end

    # Postgres does not index a foreign key for you. Both of these are on hot
    # paths: `menu_id` is the anonymous delivery read (one menu's items), and
    # `parent_id` is what the `ON DELETE CASCADE` above walks on every item
    # delete — without it, both are sequential scans of every menu item on the
    # instance.
    custom_indexes do
      index [:menu_id], name: "menu_items_menu_lookup_index", all_tenants?: true
      index [:parent_id], name: "menu_items_parent_lookup_index", all_tenants?: true
    end
  end

  actions do
    defaults [:destroy]

    default_accept [
      :menu_id,
      :parent_id,
      :label,
      :position,
      :link_type,
      :target_type,
      :target_id,
      :url,
      :open_in_new_tab,
      :visible
    ]

    create :create do
      primary? true
      change KilnCMS.CMS.Changes.SanitizeMenuItemLink
      validate KilnCMS.CMS.Validations.MenuItemDestination
      validate KilnCMS.CMS.Validations.MenuItemPlacement
    end

    update :update do
      primary? true
      require_atomic? false
      change KilnCMS.CMS.Changes.SanitizeMenuItemLink
      validate KilnCMS.CMS.Validations.MenuItemDestination
      validate KilnCMS.CMS.Validations.MenuItemPlacement
    end

    # Moving an item back to the top level, and nothing else (#900). The repair
    # for an item no chain of parents reaches a root from — the builder's
    # "Detached items" section.
    #
    # Separate from `:update` because that re-runs `MenuItemDestination` on
    # every write, and a detached item is exactly the one likely to fail it: a
    # `:url` item with a blank url, or a `:content` item whose type has since
    # been deleted, is what a restore or a direct `UPDATE` leaves behind — the
    # same causes that strand it in the first place. Gating the escape hatch on
    # the destination being valid would refuse it to the items that most need
    # it, with a message about links that has nothing to do with the problem.
    #
    # `MenuItemPlacement` is kept: it returns `:ok` immediately for a nil
    # parent, so it costs nothing here and stays in force if this action ever
    # learns to accept a real parent.
    update :reparent do
      accept [:position]
      require_atomic? false
      change set_attribute(:parent_id, nil)
      validate KilnCMS.CMS.Validations.MenuItemPlacement
    end

    read :read do
      primary? true
      prepare build(sort: [position: :asc, label: :asc])
    end
  end

  policies do
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

    # World-readable, like the menu itself.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Items are ordinary editorial furniture, so unlike a menu they may be
    # removed by any editor — deleting one is how you edit a menu.
    policy action_type(:destroy) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
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

    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Sibling order within a parent (or within the menu's root, for `parent_id`
    # nil). Ties break on label so an unordered import still reads sensibly.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    attribute :link_type, :atom do
      constraints one_of: [:content, :url, :none]
      default :content
      allow_nil? false
      public? true
    end

    # For `:content` — the same `(type name, id)` reference shape `Redirect`
    # uses. Resolved to the record's *current* published URL at read time.
    attribute :target_type, :string, public?: true
    attribute :target_id, :uuid, public?: true

    # For `:url` — sanitized on write (`Changes.SanitizeMenuItemLink`).
    attribute :url, :string, public?: true, constraints: [max_length: KilnCMS.Limits.url()]

    attribute :open_in_new_tab, :boolean, allow_nil?: false, default: false, public?: true

    # An editor's own on/off switch, independent of whether the *target* is
    # published — "hide this until the campaign launches".
    attribute :visible, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    belongs_to :menu, KilnCMS.CMS.Menu do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :parent, __MODULE__ do
      attribute_writable? true
      public? true
    end

    has_many :children, __MODULE__ do
      destination_attribute :parent_id
      public? true
    end
  end
end
