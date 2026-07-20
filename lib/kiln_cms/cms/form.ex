defmodule KilnCMS.CMS.Form do
  @moduledoc """
  An **admin-defined public form** (contact, signup, feedback, …): a slug, a
  set of typed fields (`FormField`), and submission handling — the Drupal
  Webform / WordPress forms workflow, headless-friendly.

  Forms are placed on content via the `:form` block (rendered server-side
  on-site; fired artifacts carry a `data-kiln-form` placeholder headless
  frontends hydrate from `GET /api/forms/:slug`). Submissions POST to
  `/forms/:slug` (or as JSON to `/api/forms/:slug`), are validated against
  the field definitions, honeypot-filtered and rate-limited, then stored as
  `FormSubmission`s — optionally notifying `notify_email` and firing the
  `form.submitted` webhook. Admin-managed at `/editor/forms`; an **active**
  form is world-readable so it can render publicly.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:name, :slug, :active, :inserted_at]
    label_field :name
  end

  postgres do
    table "forms"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]
    default_accept [:name, :slug, :description, :active, :success_message, :notify_email]

    create :create, primary?: true

    update :update do
      primary? true
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end

    # Public rendering / headless schema: one active form by its slug.
    read :active_by_slug do
      get? true
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug) and active == true)
    end
  end

  policies do
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Anonymous visitors may read *active* forms (that's what renders them
    # publicly); everything else form-shaped is for editors and up.
    policy action_type(:read) do
      authorize_if action(:active_by_slug)
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Building forms is an admin concern (like webhooks / field definitions).
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  changes do
    # Embedded on arbitrary published pages via the :form block — bust wide.
    change KilnCMS.CMS.Changes.BustFormCache, on: [:create, :update, :destroy]
  end

  validations do
    validate match(:slug, ~r/\A[a-z0-9][a-z0-9\-]*\z/) do
      message "must be lowercase letters, digits and dashes"
    end

    validate match(:notify_email, ~r/\A[^\s@]+@[^\s@]+\z/) do
      where present(:notify_email)
      message "must be an email address"
    end
  end

  # Multi-tenancy (epic #336): a form belongs to one site, so its slug is unique
  # per org (two sites can each have a `/contact` form). `global?: true` keeps the
  # tenant optional; tenant-less reads/writes land in the default org. No
  # companion slug index — `forms` is a tiny admin-defined table.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped create,
    # else the default org; never accepted from input (`writable?: false`, absent
    # from `default_accept`) — the cross-site boundary.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :name, :string, allow_nil?: false, public?: true

    # The public handle: POST /forms/<slug>, GET /api/forms/<slug>.
    attribute :slug, :string, allow_nil?: false, public?: true

    attribute :description, :string, public?: true

    # Inactive forms 404 publicly and reject submissions.
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true

    # Shown (or returned) after a successful submission.
    attribute :success_message, :string, public?: true

    # When set, each submission is mailed here (via the :mail queue).
    attribute :notify_email, :string, public?: true

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

    has_many :fields, KilnCMS.CMS.FormField do
      sort position: :asc, name: :asc
      public? true
    end

    has_many :submissions, KilnCMS.CMS.FormSubmission
  end

  aggregates do
    count :submission_count, :submissions
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
