defmodule KilnCMS.CMS.IpBlockRule do
  @moduledoc """
  One entry of a site's IP block list (#2242): an address or CIDR range whose
  requests the site refuses, with an optional note and expiry.

  Enforcement is `KilnCMS.Security.IpBlocklist` and the plug/socket hooks built
  on it; this resource is only the operator's rule list.

  ## Shape

    * `cidr` — a string, not a Postgres `inet`: stored in the one spelling
      `KilnCMS.Security.Cidr.normalise/1` produces (host bits masked, IPv6
      compressed, IPv4-mapped IPv6 folded to IPv4), so `[:org_id, :cidr]` is
      unique per range however it was typed. Loopback and ranges wider than
      `/8` (IPv4) or `/16` (IPv6) are refused on write
      (`Changes.NormalizeIpBlockCidr`).
    * `expires_at` — optional (the scanner guard, #2253, always sets one); a rule stops matching at that instant (evaluated
      at match time, the row is not swept) and must be in the future when set.
      Adding a range whose earlier rule has expired replaces that row
      (`Changes.ReplaceExpiredIpBlock`); an active duplicate is still refused.
    * No update: a rule is replaced by deleting it and adding another.

  ## Who

  Org-admin only, on every action including the read: the list says which
  addresses an operator is worried about. The request path never reads it as a
  person — the matcher reads it as a system actor.

  ## Not an API surface

  Deliberately absent from JSON:API, GraphQL and the MCP tools. A block list
  that can be edited over a scoped API key is a way to lock a site out of
  itself; it is edited in the console.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ip_block_rules"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end

    create :create do
      primary? true
      accept [:cidr, :note, :expires_at]

      # Self-lockout guard (#2242): a rule that contains the caller's own address
      # (or one whose address is unknown) is refused unless confirmed. The caller
      # passes its address as `context: %{client_ip: tuple | nil}`.
      argument :confirm_self_block, :boolean, default: false, allow_nil?: false, public?: true

      # Audit log (#2241), in the transaction: a site's access rules.
      change KilnCMS.Security.Changes.RecordOrgSetting
    end

    destroy :destroy do
      primary? true
      # The bust change is an after_transaction hook, which cannot be atomic.
      require_atomic? false

      # Audit log (#2241), in the transaction.
      change KilnCMS.Security.Changes.RecordOrgSetting
    end
  end

  policies do
    # Org admin on every action; a platform admin is `:admin` on every org via
    # `Scoping.effective_tier/2`. Nobody else reads or writes — editors and
    # viewers included — and there is no anonymous clause.
    #
    # The request path reads the list as the `:ip_block` system actor, the one
    # action it is granted (`:list`). An operator at a shell on the host
    # (`KilnCMS.Release.ip_blocks/1`, the way back in after a lock-out) is
    # `:operator`: `list` and `destroy`, never `create`. The scanner guard (#2253)
    # adds temporary rules for addresses that probe the site and may do nothing
    # else here: it neither lists nor removes. No grant is a bypass.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
      forbid_unless action([:list, :destroy, :create])

      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :operator, action: [:list, :destroy]}

      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :ip_block, action: :list}
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :scanner_guard, action: :create}
    end
  end

  changes do
    change KilnCMS.CMS.Changes.NormalizeIpBlockCidr, on: [:create]
    change KilnCMS.CMS.Changes.RefuseIpSelfBlock, on: [:create]
    change KilnCMS.CMS.Changes.ReplaceExpiredIpBlock, on: [:create]
    change KilnCMS.CMS.Changes.BustIpBlocklist, on: [:create, :destroy]
  end

  validations do
    validate compare(:expires_at, greater_than: &DateTime.utc_now/0),
      on: [:create],
      where: present(:expires_at),
      message: "must be in the future"
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336): set from the tenant, never accepted
    # from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :cidr, :string do
      allow_nil? false
      public? true
      constraints max_length: 64, trim?: true, allow_empty?: false
    end

    attribute :note, :string do
      public? true
      constraints max_length: 500, trim?: true, allow_empty?: false
    end

    attribute :expires_at, :utc_datetime do
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
    identity :unique_cidr_per_org, [:org_id, :cidr], message: "is already blocked"
  end
end
