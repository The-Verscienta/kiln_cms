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

    default_accept [
      :name,
      :slug,
      :description,
      :active,
      :success_message,
      :notify_email,
      :submit_label,
      :autoresponder_enabled,
      :autoresponder_subject,
      :autoresponder_body,
      :embed_origins
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

    validate KilnCMS.CMS.Validations.FormAutoresponderTokens

    # `embed_origins` is concatenated into this form's `frame-ancestors` (#648),
    # so it is checked with the same predicate as the per-site CSP lists rather
    # than a looser one: full origin, no keyword sources, no bare `*`, and no
    # character that could end the directive or the header.
    validate {KilnCMS.CMS.Validations.CspOrigins, fields: [:embed_origins]}

    # After the shape check, and only under `EMBED_ORIGINS_LOCKED` (#1133): a
    # list that reaches outside the operator's ceiling is refused, naming the
    # offending entries and never the ceiling. See `KilnCMS.Forms.EmbedCeiling`.
    validate {KilnCMS.CMS.Validations.EmbedCeiling, field: :embed_origins}
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

    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # The public handle: POST /forms/<slug>, GET /api/forms/<slug>.
    attribute :slug, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    attribute :description, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # Inactive forms 404 publicly and reject submissions.
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true

    # Shown (or returned) after a successful submission.
    attribute :success_message, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # When set, each submission is mailed here (via the :mail queue).
    attribute :notify_email, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # Submit-button text; nil falls back to the translated "Submit".
    attribute :submit_label, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # The autoresponder (#468, docs/form-builder-plan.md phase 6): a
    # confirmation email sent to the *submitter*, not the admin — separate
    # from `notify_email` above. Only ever fires when the form actually has
    # an `:email` field and the submission gave it a non-blank value; see
    # `KilnCMS.Forms.Autoresponder.eligible?/3`.
    attribute :autoresponder_enabled, :boolean do
      allow_nil? false
      default false
      public? true
    end

    # `Kiln.Tokens` patterns (#468) — `[field:<name>]` per the form's own
    # fields plus `[form-name]`, validated by
    # `KilnCMS.CMS.Validations.FormAutoresponderTokens`. Required (non-blank)
    # only while `autoresponder_enabled` is true.
    attribute :autoresponder_subject, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    attribute :autoresponder_body, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # Which parent sites may frame *this* form's embed page (#648) — `nil` to
    # inherit the deployment's `EMBED_ORIGINS`, `[]` for same-origin only
    # whatever the deployment allows, or this form's own allowlist instead of
    # the deployment's. `KilnCMSWeb.Embed` holds the argument for why the
    # allowlist belongs on the form and not on one deployment-wide variable;
    # `nil` vs `[]` is the distinction to preserve when touching this.
    #
    # Bounded because these are concatenated into a response HEADER, and a
    # reverse proxy answers 502 rather than truncating: nginx's default
    # `proxy_buffer_size` is 4 KB. 16 origins at the 253-byte DNS name limit is
    # ~4 KB of sources — already more than any real allowlist and near the
    # smallest limit in the wild, so the cap is 16 rather than the 32
    # `SiteCodeInjection` uses across three lists on a different header.
    attribute :embed_origins, {:array, :string},
      public?: true,
      constraints: [max_length: 16, items: [max_length: 253]]

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
