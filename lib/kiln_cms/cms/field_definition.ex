defmodule KilnCMS.CMS.FieldDefinition do
  @moduledoc """
  A **runtime-defined custom field** on a content type — the admin-UI-first
  half of the schema (the Directus "add a field in the UI" workflow), within the
  constraints of decision D4.

  D4 keeps content *types* as compile-time Ash resources; this makes their
  *fields* data-driven. An admin defines typed fields per content type here
  (name, type, whether required, select options, …); the values live in the
  `custom_fields` map on each content record and are coerced + validated against
  these definitions on write (see `KilnCMS.CMS.Changes.ApplyCustomFields`). The
  content editor renders an input per definition, so editors add structured
  fields without a code change or migration.

  A definition is scoped to **exactly one** of two owners (D17):

    * `content_type` — a compiled content type's atom (`:page`), the original
      D4 scope; or
    * `type_definition_id` — an admin-defined dynamic type
      (`KilnCMS.CMS.TypeDefinition`), whose entire schema is these rows.

  This deliberately does *not* replace hand-declared attributes: core, queryable,
  or strongly-typed fields still belong in the resource. It covers the long tail
  of editor-owned fields that would otherwise mean a migration per field.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  @doc """
  The value types a custom field may declare: the built-ins plus every
  plugin-contributed `Kiln.FieldType` (see `KilnCMS.CMS.FieldTypes`).
  """
  @spec field_types() :: [atom()]
  def field_types, do: KilnCMS.CMS.FieldTypes.names()

  admin do
    resource_group :content
    table_columns [:content_type, :name, :label, :field_type, :required, :position]
    relationship_display_fields [:label]
    label_field :label
  end

  postgres do
    table "field_definitions"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :content_type,
      :type_definition_id,
      :name,
      :label,
      :field_type,
      :required,
      :options,
      :target_type,
      :help_text,
      :position,
      :default
    ]

    create :create, primary?: true

    # Non-atomic: the KnownContentType validation runs in Elixir.
    update :update do
      primary? true
      require_atomic? false
    end

    # All custom-field definitions for one content type, in editor display order.
    # Used by the editor (to render inputs) and the content write change (to
    # coerce/validate values) — both call it with `authorize?: false`.
    read :for_type do
      argument :content_type, :atom, allow_nil?: false
      filter expr(content_type == ^arg(:content_type))
      prepare build(sort: [position: :asc, name: :asc])
    end

    # The dynamic-type equivalent of `for_type`: all field definitions owned by
    # one `TypeDefinition`, in editor display order.
    read :for_definition do
      argument :type_definition_id, :uuid, allow_nil?: false
      filter expr(type_definition_id == ^arg(:type_definition_id))
      prepare build(sort: [position: :asc, name: :asc])
    end
  end

  policies do
    # Admins own the schema (defining/removing fields is an admin concern).
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Editors may read definitions so the content editor can render the fields.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Only admins define, change or remove fields.
    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  validations do
    # A field belongs to exactly one owner: a compiled type XOR a dynamic one.
    validate KilnCMS.CMS.Validations.OneFieldScope

    # When compiled-scoped, the content type must be a real, registered
    # KilnCMS content type (no-op when `content_type` is nil).
    validate KilnCMS.CMS.Validations.KnownContentType

    # `field_type` must be registered: a built-in or a plugin `Kiln.FieldType`.
    validate KilnCMS.CMS.Validations.KnownFieldType

    # `name` is the key inside the `custom_fields` map and is surfaced in the
    # delivery API, so keep it a safe machine identifier. `or`/`and` are
    # excluded: they're the reserved combinator keys of the `custom_filter`
    # query syntax (see `Preparations.CustomFieldQuery`).
    validate match(:name, ~r/\A(?!(?:or|and)\z)[a-z][a-z0-9_]*\z/) do
      message "must be lowercase letters, digits and underscores, starting with a letter " <>
                "(\"or\" and \"and\" are reserved)"
    end

    # A :select field is meaningless without choices.
    validate KilnCMS.CMS.Validations.SelectOptions

    # A :reference field must target a known content type (compiled or dynamic).
    validate KilnCMS.CMS.Validations.ReferenceTarget
  end

  attributes do
    uuid_primary_key :id

    # Which compiled content type this field is attached to (atom, e.g.
    # `:page`) — nil for a field owned by a dynamic type (see the
    # `type_definition` relationship and `Validations.OneFieldScope`).
    attribute :content_type, :atom, public?: true

    # Machine key inside the `custom_fields` map.
    attribute :name, :string, allow_nil?: false, public?: true

    # Human label shown in the editor and (optionally) on delivery.
    attribute :label, :string, allow_nil?: false, public?: true

    # No `one_of` constraint: the allowed set includes plugin-registered types
    # (`KilnCMS.CMS.FieldTypes.names/0`), enforced by `Validations.KnownFieldType`
    # so the check reads the registry rather than a compile-baked constraint.
    attribute :field_type, :atom do
      default :string
      allow_nil? false
      public? true
    end

    # Whether the editor must supply a value.
    attribute :required, :boolean, allow_nil?: false, default: false, public?: true

    # Choices for a `:select` field (ignored otherwise).
    attribute :options, {:array, :string}, allow_nil?: false, default: [], public?: true

    # The content type a `:reference` field points at — a type name string
    # ("page", "recipe", …), compiled or dynamic (ignored otherwise).
    attribute :target_type, :string, public?: true

    # Optional helper text rendered under the input.
    attribute :help_text, :string, public?: true

    # Display order within a content type's custom-field section.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Optional default value (stored as a string, coerced to the field type when
    # an editor leaves the input blank).
    attribute :default, :string, public?: true

    timestamps()
  end

  relationships do
    # The dynamic type owning this field (nil for compiled-scoped fields).
    belongs_to :type_definition, KilnCMS.CMS.TypeDefinition do
      allow_nil? true
      public? true
    end
  end

  identities do
    # One field name per owner. Two identities, one per scope — Postgres treats
    # NULLs as distinct, so each acts as a partial unique index over the rows
    # where its scope column is set.
    identity :unique_field, [:content_type, :name]
    identity :unique_definition_field, [:type_definition_id, :name]
  end
end
