defmodule KilnCMS.Mail.SiteSuppressedRecipient do
  @moduledoc """
  An address **one site's own SMTP relay** hard-bounced (#1562): a permanent
  reject naming the recipient (`5.1.1`, `5.2.1`, ...), answered by the relay the
  site set at `/editor/site-mail` (`KilnCMS.Mail.SiteRelay`).

  The per-site twin of `KilnCMS.Mail.SuppressedRecipient`, and deliberately a
  separate table rather than an `org_id` column on that one, because the two are
  believed to different degrees:

    * **The instance-wide list is the operator's relay's word**, and it stops an
      address everywhere — every site's mail and account mail (sign-in links,
      password resets) alike.
    * **This list is a site's relay's word.** That relay is a server the site
      chose, and it can answer 550 to any address it likes. So its word stops
      only that site's own mail to the address, and nothing else: not another
      site's, not the operator's, and never account mail, which carries no site
      (`KilnCMS.Mail.enqueue!/2` without `org_id:`) and so never consults a
      site's list. The worst a malicious relay can do with this table is stop
      mail its own site sends — which the site's admin could stop anyway.

  Written only by the delivery pipeline (`KilnCMS.Mail.deliver_for_worker/2`),
  as the system, when the site's relay rejected a recipient; never by a caller.
  Consulted, for mail sent *for this site*, alongside the instance-wide list
  (`KilnCMS.Mail.suppressed?/2`): by `KilnCMS.Mail.enqueue!/2` and the
  newsletter worker. Listed, and removable, on the site's `/editor/site-mail`
  page by the site's admins.

  The address is a `ci_string`, so suppression and lookup are case-insensitive.
  """
  use Ash.Resource,
    domain: KilnCMS.Mail,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_suppressed_recipients"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Upsert: a repeat bounce for an already-suppressed address refreshes the
    # reason and timestamp rather than erroring on the identity, which is
    # per-site — the tenant attribute is part of it.
    create :suppress do
      accept [:email, :reason]
      upsert? true
      upsert_identity :unique_site_email
      upsert_fields [:reason, :last_failure_at]
      change set_attribute(:last_failure_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # The site's admins see and clear their own site's list, from
    # `/editor/site-mail`. Tenant-scoped reads never reach another site's rows.
    policy action_type([:read, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end

    # Written only by the delivery pipeline (`authorize?: false`), on a site
    # relay's reject naming the recipient. A caller who could add rows could
    # stop a site's mail to anyone without a bounce ever happening.
    policy action_type(:create) do
      forbid_if always()
    end
  end

  # The tenancy boundary (epic #336): a row belongs to the site whose relay
  # rejected the address, and is read under that site alone.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The site whose relay rejected the address. Set from the tenant; never
    # accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :email, :ci_string, allow_nil?: false, public?: true

    # The redacted SMTP reason for the bounce (never contains the address).
    attribute :reason, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    attribute :last_failure_at, :utc_datetime_usec, public?: true

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
    # Scoped to the tenant: `(org_id, email)`.
    identity :unique_site_email, [:email]
  end
end
