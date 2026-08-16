defmodule KilnCMS.CMS.SiteEmbedSettings do
  @moduledoc """
  Per-org default for who may frame a form's embed page (#1131).

  Follow-up to #648, which put the `frame-ancestors` allowlist on the
  **form**: correct for "this one partner needs this one form," but an org
  with a dozen forms sets the same allowlist a dozen times, and every form
  that has never been opened — every existing one, and every new one — is
  still governed by the deployment-wide `EMBED_ORIGINS` until somebody does.
  On a multi-org deployment that variable is necessarily the union of every
  org's embedders, which is #562's overlay-and-harvest attack one tenant
  boundary over.

  This resource is the middle rung `KilnCMS.Forms.EmbedPolicy` resolves:

      form.embed_origins  ->  SiteEmbedSettings.embed_origins  ->  EMBED_ORIGINS

  `KilnCMS.CMS.Form`'s own three states apply here unchanged, and for the
  same reason — `nil` (no row, or a row with `embed_origins: nil`) means
  "this org has not set a default, fall through to the deployment"; `[]`
  means "same-origin only for every form in this org that hasn't set its
  own," a deliberate close distinct from absence; a non-empty list is this
  org's allowlist. `KilnCMS.Forms.EmbedPolicy.effective/1` is where those
  states get read and folded into a form's effective policy — nothing else
  should read this resource directly, the same "own_origins/1 is the only
  reader of the shape" discipline `KilnCMSWeb.Embed` documents for the form
  half of the ladder.

  Admin-only, like `KilnCMS.CMS.FormSpamSettings` (never delivered to a
  visitor, no `paper_trail`), managed through the generic Ash Admin resource
  UI rather than a bespoke settings page — this is a short-lived allowlist an
  org admin edits rarely, not something that needs its own polished screen.
  One row per org, created lazily by `:save` so a site that never sets a
  default costs nothing.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:embed_origins, :updated_at]
  end

  postgres do
    table "site_embed_settings"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:embed_origins]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:embed_origins]
    end

    update :update do
      primary? true
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Never delivered — this is the operator-facing half of a framing policy,
    # not content; no public read, unlike SiteBranding/SiteCodeInjection.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  validations do
    # Same predicate `Form.embed_origins` uses — this list is concatenated
    # into the same header, so it is the same hazard: keyword sources and
    # header-injection characters, checked here rather than trusting every
    # form's own validation to catch a value that never passed through it.
    validate {KilnCMS.CMS.Validations.CspOrigins, fields: [:embed_origins]}

    # After the shape check, and only under `EMBED_ORIGINS_LOCKED` (#1133): a
    # list that reaches outside the operator's ceiling is refused, naming the
    # offending entries and never the ceiling. See `KilnCMS.Forms.EmbedCeiling`.
    validate {KilnCMS.CMS.Validations.EmbedCeiling, field: :embed_origins}
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

    # Same three states, same bound, as `Form.embed_origins` — see that
    # attribute's doc for why `nil` and `[]` must stay distinct, and why 16
    # entries at the DNS name limit.
    attribute :embed_origins, {:array, :string},
      public?: true,
      constraints: [max_length: 16, items: [max_length: 253]]

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
