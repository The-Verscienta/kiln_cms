defmodule KilnCMS.CMS.SitePasswordPolicy do
  @moduledoc """
  A site's stance on breached passwords (#2240): whether a password found in
  a public breach corpus is let through silently (`:off`), allowed with a
  warning (`:warn`, the default) or refused for the accounts that matter most
  (`:block`, admins only).

  `KilnCMS.Accounts.PasswordPolicy` resolves it: this row, then the operator's
  default (`BREACHED_PASSWORD_POLICY`), then `:warn`. The check itself is
  `KilnCMS.Accounts.BreachedPassword`.

  One row per organization, created lazily by `:save`, admin-only to read and
  write — the `KilnCMS.CMS.SiteEmbedSettings` shape. There is no `paper_trail`
  history and nothing here is delivered to a visitor.

  The credential actions read it as `KilnCMS.OrgSettings.system(:accounts)`
  (`system_actions:` admits the reads and nothing else), because a registration
  or a password reset has no admin actor to read it as. Writing the row stays an
  admin act.

  ## Reading across orgs (#2408)

  A password set by an administrator is held to the strictest policy of every
  site they administer, not only the one the request came in on. `:for_orgs`
  (the rows of the named orgs) and `:all_orgs` (every org's, for a platform
  admin) are `multitenancy :bypass` reads for that, and they are the system
  actor's **alone**: the macro's read policy admits a site's own admin, and
  through a tenant-less read that would be every site's row.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_password_policy",
    accept: [:breached_password_policy],
    read: :admin,
    admin_columns: [:breached_password_policy, :updated_at],
    system_actions: [read: :accounts, for_orgs: :accounts, all_orgs: :accounts]

  attributes do
    # `:warn` for a row created without a value, matching the resolved default
    # when a site has no row at all.
    attribute :breached_password_policy, :atom do
      default :warn
      allow_nil? false
      public? true
      constraints one_of: [:off, :warn, :block]
    end
  end

  actions do
    # The rows of the orgs an account administers (#2408). Cross-org by
    # nature, so a sanctioned `multitenancy :bypass` read: a tenant-less read
    # of the primary `:read` is refused under strict tenancy. An empty list is
    # refused rather than read as "every org" (that is `:all_orgs`, by name).
    read :for_orgs do
      description "The password policy rows of the given orgs (the breached-password check)."
      multitenancy :bypass
      argument :org_ids, {:array, :uuid}, allow_nil?: false, constraints: [min_length: 1]
      filter expr(org_id in ^arg(:org_ids))
    end

    # Every org's row: a platform admin administers every site (#2408).
    read :all_orgs do
      description "Every org's password policy row (the breached-password check)."
      multitenancy :bypass
    end
  end

  policies do
    # The cross-org reads are the breached-password check's alone. Ash ANDs
    # policies, so this one refuses a person even though the macro's read
    # policy (`OrgAdmin`) would admit a site admin, who must not list every
    # site's stance through a tenant-less read.
    policy action([:for_orgs, :all_orgs]) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :accounts}
    end
  end
end
