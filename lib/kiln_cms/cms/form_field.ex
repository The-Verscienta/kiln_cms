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
  # reference pickers on anonymous forms).
  @field_types [:string, :text, :email, :integer, :boolean, :date, :select]

  @doc "The value types a form field may declare."
  @spec field_types() :: [atom()]
  def field_types, do: @field_types

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
      :width
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

    # Fields render on public forms, so `:for_form` stays open to anonymous
    # visitors — but only for a form that is actually public. This mirrors the
    # parent's rule (`Form` grants anonymous reads through `:active_by_slug`,
    # which filters `active == true`); previously the child granted every read
    # unconditionally, so the fields of an *inactive* form were readable
    # directly (#565).
    #
    # One policy over *every* read action, not a narrower one for `:for_form`:
    # the public render path is `Forms.get_active/2`, which loads `[:fields]` as
    # an anonymous but **authorized** read, and a relationship load runs the
    # resource's primary `:read`. Splitting the grant per action would leave that
    # load matching an editors-only policy and silently render a form with no
    # fields — a load filters rather than errors, so nothing would announce it.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if expr(form.active == true)
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

    # A :select field is meaningless without choices.
    validate KilnCMS.CMS.Validations.SelectOptions
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :field_type, :atom do
      constraints one_of: @field_types
      default :string
      allow_nil? false
      public? true
    end

    attribute :required, :boolean, allow_nil?: false, default: false, public?: true
    attribute :options, {:array, :string}, allow_nil?: false, default: [], public?: true

    attribute :help_text, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true

    attribute :placeholder, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Pre-filled value: the input's initial value ("true" pre-checks a boolean,
    # a select pre-picks the matching option). Stored as text; submission-time
    # coercion in `KilnCMS.Forms` applies to whatever value comes back.
    attribute :default_value, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Display width on the public form's 6-column grid.
    attribute :width, :atom do
      constraints one_of: [:full, :half, :third]
      default :full
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
