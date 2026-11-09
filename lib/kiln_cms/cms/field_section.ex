defmodule KilnCMS.CMS.FieldSection do
  @moduledoc """
  How one **section** of a content type's custom fields is laid out in the
  editor (#2280): as a collapsible accordion, an always-open fieldset, or one
  tab of the type's tab set.

  A section is not a row of its own: it is the `section` string a
  `KilnCMS.CMS.FieldDefinition` is filed under, shared by name, and its place
  in the panel is the place of its first field. This resource holds only the
  presentation of a section that has one, keyed by the same owner and name.
  A section with no row here renders as it always has: an accordion that opens
  by the panel's own heuristic (`display: :accordion`, `initially: :auto`).

  Scoped like a field: to **exactly one** of a compiled content type
  (`content_type`) or a dynamic one (`type_definition_id`). Link fields and
  group sub-fields have no section, so neither owner of theirs appears here.

  A row whose name no field carries any more (the last field of a section
  renamed it) is harmless — nothing renders or exports it — and the fields
  admin prunes it when it next saves that type's sections
  (`KilnCMS.CMS.SectionLayouts`). Deleting a section's last field, in the
  admin or by a pruning field sync import, drops its row at once.

  Editor-only, like `section` itself: it changes nothing about a value, its
  validation or its delivery. The schema export reports a non-accordion
  display as `x-kiln-section-display` on each field of the section.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @displays [:accordion, :fieldset, :tab]
  @initial_states [:auto, :expanded, :collapsed]

  @doc "How a section may be laid out."
  @spec displays() :: [atom()]
  def displays, do: @displays

  @doc """
  Whether an accordion section starts open: `:auto` (the panel's heuristic),
  `:expanded` or `:collapsed`. Ignored for a fieldset or a tab.
  """
  @spec initial_states() :: [atom()]
  def initial_states, do: @initial_states

  postgres do
    table "field_sections"
    repo KilnCMS.Repo

    references do
      # A dynamic type is archived, not deleted, so this rarely fires; when a
      # type row does go, its layout has nothing left to describe.
      reference :type_definition, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:content_type, :type_definition_id, :name, :display, :initially]
    end

    # The owner and the name are the row's key, so only the layout changes.
    # Non-atomic, like the destroy: `Changes.BustFieldLayout` needs the record
    # after the transaction. Admin-only and rare, so the atomic path costs
    # nothing.
    update :update do
      primary? true
      require_atomic? false
      accept [:display, :initially]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end

    # A compiled type's section layouts, by name. Read by the editor, the
    # fields admin and the schema export.
    read :for_type do
      argument :content_type, :atom, allow_nil?: false
      filter expr(content_type == ^arg(:content_type))
      prepare build(sort: [name: :asc])
    end

    # The dynamic-type twin of `for_type`.
    read :for_definition do
      argument :type_definition_id, :uuid, allow_nil?: false
      filter expr(type_definition_id == ^arg(:type_definition_id))
      prepare build(sort: [name: :asc])
    end
  end

  policies do
    # Admins own the schema, the layout of its fields included.
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Editors read a type's layout so the content editor can render it. The
    # schema export reads it as its own system actor (`KilnCMS.SchemaExport`),
    # as it reads the field definitions themselves.
    policy action_type(:read) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: [:schema_export]}
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Only admins lay out fields.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    # The cached type registry and delivery schema carry the layout. A
    # global change skips destroys unless named.
    change KilnCMS.CMS.Changes.BustFieldLayout, on: [:create, :update, :destroy]
  end

  validations do
    validate present([:content_type, :type_definition_id], exactly: 1) do
      message "a section belongs to exactly one of a content type or a type definition"
    end

    validate KilnCMS.CMS.Validations.KnownContentType
  end

  # Multi-tenancy (epic #336), as `FieldDefinition`: a layout belongs to the
  # site whose type it lays out.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336), set from the tenant; never input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The compiled content type this layout belongs to — nil for a dynamic
    # type's. Loads a vanished type as `KilnCMS.CMS.OrphanedContentType`.
    attribute :content_type, KilnCMS.CMS.Types.StoredContentType, public?: true

    # The `section` string of the fields it lays out.
    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :display, :atom do
      allow_nil? false
      default :accordion
      constraints one_of: @displays
      public? true
    end

    attribute :initially, :atom do
      allow_nil? false
      default :auto
      constraints one_of: @initial_states
      public? true
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

    # The dynamic type this layout belongs to (nil for a compiled type's).
    belongs_to :type_definition, KilnCMS.CMS.TypeDefinition do
      allow_nil? true
      public? true
    end
  end

  identities do
    # One layout per section name per owner per org (Ash prepends `org_id`);
    # one identity per scope, as `FieldDefinition` keys its names.
    identity :unique_section, [:content_type, :name]
    identity :unique_definition_section, [:type_definition_id, :name]
  end
end
