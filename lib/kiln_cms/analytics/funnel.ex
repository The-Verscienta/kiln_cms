defmodule KilnCMS.Analytics.Funnel do
  @moduledoc """
  An admin-authored, ordered list of content items (landing → pricing →
  signup) — phase 4 of `docs/advanced-analytics-plan.md` (design doc from
  #62). A **definition only**: conversion counts are derived at read time
  from `KilnCMS.Analytics.ContentViewDay` buckets (#622), never stored here
  or in a per-funnel counter table (see the design doc, "Funnels —
  definitions only, counts derived", for why a `FunnelStepDay` counter table
  was rejected — retroactive reporting, nothing new on the delivery path, no
  second retention story).

  Unlike every other resource in this domain, a funnel is editorial data an
  admin writes directly — the first genuinely writable resource here, with a
  real policy block (admin-only create/update/destroy, `OrgEditor` read)
  rather than the counter resources' `forbid_if always()` on every write.
  """
  use Ash.Resource,
    domain: KilnCMS.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "funnels"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:name, :slug, :active]

    create :create, primary?: true

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
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Reading funnels (to see the report, #622) is editor/admin only, same
    # tier as the rest of this domain.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Defining funnels is an admin concern (like webhooks / forms).
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  validations do
    validate match(:slug, ~r/\A[a-z0-9][a-z0-9\-]*\z/) do
      message "must be lowercase letters, digits and dashes"
    end
  end

  # Multi-tenancy (epic #336): a funnel belongs to one site, same pattern as
  # every other resource in this domain.
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

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    has_many :steps, KilnCMS.Analytics.FunnelStep do
      sort position: :asc
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
