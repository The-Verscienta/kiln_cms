defmodule KilnCMS.CMS.FormField do
  @moduledoc """
  One typed field on an admin-defined `Form` (`/editor/forms`): machine name
  (the key in each submission's `data` map), label, value type, whether it's
  required, select options, help text, and display order. Validated + coerced
  on every submission by `KilnCMS.Forms` — the form cousin of
  `FieldDefinition`, kept separate so public form rendering never loosens the
  content-schema policies.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # Submission value types — JSON-native, public-input-friendly (no media /
  # reference pickers on anonymous forms). :heading and :divider are
  # display-only (no submission value); :hidden carries its default_value;
  # :page_break splits the form into steps (phase 5) and is display-only too.
  @field_types [
    :string,
    :text,
    :email,
    :phone,
    :url,
    :integer,
    :number,
    :date,
    :select,
    :radio,
    :checkboxes,
    :boolean,
    :rating,
    :consent,
    :heading,
    :divider,
    :page_break,
    :hidden
  ]

  # Types whose value is one/many of the admin-listed `options`.
  @choice_types [:select, :radio, :checkboxes]

  # Types that never produce a submission value.
  @display_types [:heading, :divider, :page_break]

  @doc "The value types a form field may declare."
  @spec field_types() :: [atom()]
  def field_types, do: @field_types

  @doc "Types whose value comes from the admin-listed `options`."
  @spec choice_types() :: [atom()]
  def choice_types, do: @choice_types

  @doc "Display-only types (no submission value)."
  @spec display_types() :: [atom()]
  def display_types, do: @display_types

  admin do
    resource_group :content
    table_columns [:form_id, :name, :label, :field_type, :required, :position]
    label_field :label
  end

  postgres do
    table "form_fields"
    repo KilnCMS.Repo

    references do
      reference :form, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    default_accept [
      :form_id,
      :name,
      :label,
      :field_type,
      :required,
      :options,
      :help_text,
      :position,
      :placeholder,
      :default_value,
      :width,
      :validation,
      :conditions
    ]

    create :create, primary?: true

    update :update do
      primary? true
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end

    # All fields of one form, in display order (public rendering + coercion).
    read :for_form do
      argument :form_id, :uuid, allow_nil?: false
      filter expr(form_id == ^arg(:form_id))
      prepare build(sort: [position: :asc, name: :asc])
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Fields render on public forms — world-readable (the parent form's
    # `active` flag is the visibility gate, enforced where forms are fetched).
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  changes do
    # Embedded on arbitrary published pages via the :form block — bust wide.
    change KilnCMS.CMS.Changes.BustFormCache, on: [:create, :update, :destroy]
  end

  validations do
    # `name` keys the submission data map and is echoed in the public schema.
    validate match(:name, ~r/\A[a-z][a-z0-9_]*\z/) do
      message "must be lowercase letters, digits and underscores, starting with a letter"
    end

    # A choice field (select/radio/checkboxes) is meaningless without choices.
    validate KilnCMS.CMS.Validations.SelectOptions

    # Validation-rule map: known keys, sane numbers, compilable pattern.
    validate KilnCMS.CMS.Validations.FieldRules

    # Conditional-logic map: known shape, known operators.
    validate KilnCMS.CMS.Validations.FieldConditions
  end

  # Multi-tenancy (epic #336): a field belongs to the same site as its form.
  # `global?: true` keeps the tenant optional; tenant-less reads/writes land in
  # the default org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (propagated from
    # the parent form on create), else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :label, :string, allow_nil?: false, public?: true

    attribute :field_type, :atom do
      constraints one_of: @field_types
      default :string
      allow_nil? false
      public? true
    end

    attribute :required, :boolean, allow_nil?: false, default: false, public?: true
    attribute :options, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :help_text, :string, public?: true
    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    attribute :placeholder, :string, public?: true

    # Pre-filled value: the input's initial value ("true" pre-checks a boolean,
    # a select pre-picks the matching option). Stored as text; submission-time
    # coercion in `KilnCMS.Forms` applies to whatever value comes back.
    attribute :default_value, :string, public?: true

    # Display width on the public form's 6-column grid.
    attribute :width, :atom do
      constraints one_of: [:full, :half, :third]
      default :full
      allow_nil? false
      public? true
    end

    # Per-field validation rules, enforced server-side by `KilnCMS.Forms` and
    # mirrored as HTML attributes client-side. String keys (JSONB):
    # "min_length"/"max_length" (strings), "min"/"max" (numbers),
    # "pattern" (anchored regex, must compile — see FieldRules),
    # "message" (custom error text overriding the rule defaults).
    attribute :validation, :map do
      default %{}
      allow_nil? false
      public? true
    end

    # Conditional visibility ("smart logic"). String keys (JSONB):
    # %{"logic" => "all" | "any",
    #   "rules" => [%{"field" => name, "operator" => op, "value" => v}]}
    # with operators eq/neq/contains/empty/not_empty/gt/lt. Empty map = always
    # shown. Evaluated client-side (form-conditions.js) for UX and re-evaluated
    # server-side in `KilnCMS.Forms` as the authority — a hidden field skips
    # `required` and its submitted value is discarded.
    attribute :conditions, :map do
      default %{}
      allow_nil? false
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

    belongs_to :form, KilnCMS.CMS.Form do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_form_field, [:form_id, :name]
  end
end
