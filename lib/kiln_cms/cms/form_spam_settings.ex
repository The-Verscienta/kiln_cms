defmodule KilnCMS.CMS.FormSpamSettings do
  @moduledoc """
  Per-org configuration for the form spam scorer (#477): a disallowed-keyword
  list, checked by `Kiln.Forms.SpamCheck.Checks.DisallowedKeywords`.

  One row per organization — the `KilnCMS.CMS.SiteBranding` shape, not
  `KilnCMS.CMS.SiteCodeInjection`'s: this is admin-only settings, never
  rendered to a visitor, so it carries no `paper_trail` history and no public
  read policy. The row is created lazily by `:save` (upsert on the
  one-per-org identity) — never by a read, so a site with no configured
  keywords costs nothing until an admin actually sets some. Edited on
  `/editor/forms/settings` (`KilnCMSWeb.FormSettingsLive`, #1232).
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:keywords, :updated_at]
  end

  postgres do
    table "form_spam_settings"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:keywords]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:keywords]
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
    # Never delivered — an org's keyword list is not public information the
    # way branding/code-injection are, so unlike those, no public read here.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

    # Case-insensitive substring matches against every free-text field value
    # a submission carries. Bounded the same way `SiteCodeInjection`'s origin
    # lists are: a settings value should never be able to make the scorer's
    # per-submission work unbounded.
    attribute :keywords, {:array, :string},
      default: [],
      public?: true,
      constraints: [max_length: 200, items: [max_length: 100]]

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
