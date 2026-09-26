defmodule KilnCMS.CMS.SiteSsoDomain do
  @moduledoc """
  An email domain a site's single sign-on provider may vouch for (#1561), and
  the DNS proof that the site controls it.

  Accounts belong to the whole deployment. A provider a site admin pointed Kiln
  at could assert *any* address — including that of an admin on another site —
  so `KilnCMS.Accounts.SiteSso` honours an assertion only when the address is in
  a domain listed here **and** verified: the site published
  `kiln-sso-verification=<token>` as a TXT record at `_kiln-sso.<domain>`.

  Whoever controls a domain's DNS controls where its mail goes, and so could
  already take over its accounts with a password reset. Verifying DNS control
  therefore gives a site's provider no power over an address that the site
  could not already reach through the deployment's own account mail. That is
  the whole argument for why honouring such a provider is safe, and why nothing
  weaker than DNS control (a confirmation email to one mailbox, say) is used.

  ## Verification is re-checked at every sign-in

  `verified_at` records that an admin proved control once. It is necessary, not
  sufficient: `KilnCMS.Accounts.SiteSso.DomainCheck` looks the record up again
  on every sign-in, and a missing record refuses the sign-in. A domain that
  changes hands, or a site that stops publishing the record, stops being
  honoured at once rather than whenever someone remembers to press a button.
  The page says to keep the record in place.

  Exact domains only: `example.com` does not cover `mail.example.com`. Each has
  its own record.

  ## Who can see and change it

  Org admins, for every action, like the provider itself
  (`KilnCMS.CMS.SiteSsoProvider`). The verification token is not a secret — it
  is published in DNS — but it is per site and per domain, and random, so one
  site cannot satisfy another's challenge by accident or copy.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_sso_domains"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    create :add do
      primary? true
      accept [:domain]
      change KilnCMS.CMS.Changes.PrepareSsoDomain
    end

    # Looks the TXT record up now and stamps `verified_at` when it is there.
    # Not a plain attribute write: nothing may set `verified_at` except a
    # lookup that found the record.
    update :verify do
      accept []
      require_atomic? false
      change KilnCMS.CMS.Changes.VerifySsoDomain
    end

    destroy :remove do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # A site's list of vouched-for domains is its admins' business, both ways:
    # reading it names the site's identity provider's reach.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # The tenancy boundary (epic #336) — the same line `KilnCMS.CMS.OrgSettings`
  # emits for the provider row. It is what keeps one site's verified domains out
  # of another site's sign-in decision.
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

    # Lower-case, no trailing dot, at least two labels
    # (`Changes.PrepareSsoDomain`).
    attribute :domain, :string do
      allow_nil? false
      public? true
      constraints max_length: 253
    end

    # What the TXT record must carry. Generated on `:add`, never accepted.
    attribute :verification_token, :string do
      allow_nil? false
      writable? false
      public? true
      constraints max_length: 64
    end

    # When an admin's "Verify" last found the record. `nil` = never verified,
    # and the domain is not honoured.
    attribute :verified_at, :utc_datetime_usec do
      writable? false
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
  end

  identities do
    # Per site (attribute multitenancy scopes the identity to `org_id`). Two
    # sites may both list a domain; only the one whose token is in DNS is
    # honoured, and a domain owner who publishes both tokens has chosen both.
    identity :unique_domain, [:domain]
  end
end
