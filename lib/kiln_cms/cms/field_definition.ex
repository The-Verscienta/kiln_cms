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

  This deliberately does *not* replace hand-declared attributes: core, queryable,
  or strongly-typed fields still belong in the resource. It covers the long tail
  of editor-owned fields that would otherwise mean a migration per field.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # The value types a custom field can declare. Each maps to an HTML input and a
  # coercion/validation rule in `Changes.ApplyCustomFields`. Kept JSON-native so
  # values round-trip cleanly through the `custom_fields` jsonb column (dates are
  # stored as ISO-8601 strings).
  @field_types [:string, :text, :integer, :float, :boolean, :date, :datetime, :url, :select]

  @doc "The value types a custom field may declare."
  @spec field_types() :: [atom()]
  def field_types, do: @field_types

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
      :name,
      :label,
      :field_type,
      :required,
      :options,
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
    # The content type must be a real, registered KilnCMS content type.
    validate KilnCMS.CMS.Validations.KnownContentType

    # `name` is the key inside the `custom_fields` map and is surfaced in the
    # delivery API, so keep it a safe machine identifier.
    validate match(:name, ~r/\A[a-z][a-z0-9_]*\z/) do
      message "must be lowercase letters, digits and underscores, starting with a letter"
    end

    # A :select field is meaningless without choices.
    validate KilnCMS.CMS.Validations.SelectOptions
  end

  attributes do
    uuid_primary_key :id

    # Which content type this field is attached to (atom, e.g. `:page`).
    attribute :content_type, :atom, allow_nil?: false, public?: true

    # Machine key inside the `custom_fields` map.
    attribute :name, :string, allow_nil?: false, public?: true

    # Human label shown in the editor and (optionally) on delivery.
    attribute :label, :string, allow_nil?: false, public?: true

    attribute :field_type, :atom do
      constraints one_of: @field_types
      default :string
      allow_nil? false
      public? true
    end

    # Whether the editor must supply a value.
    attribute :required, :boolean, allow_nil?: false, default: false, public?: true

    # Choices for a `:select` field (ignored otherwise).
    attribute :options, {:array, :string}, allow_nil?: false, default: [], public?: true

    # Optional helper text rendered under the input.
    attribute :help_text, :string, public?: true

    # Display order within a content type's custom-field section.
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    # Optional default value (stored as a string, coerced to the field type when
    # an editor leaves the input blank).
    attribute :default, :string, public?: true

    timestamps()
  end

  identities do
    # One field name per content type.
    identity :unique_field, [:content_type, :name]
  end
end
