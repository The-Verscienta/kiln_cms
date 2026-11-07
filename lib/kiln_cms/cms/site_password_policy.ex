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
  (`system_actions:` admits `read` and nothing else), because a registration or
  a password reset has no admin actor to read it as. Writing the row stays an
  admin act.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_password_policy",
    accept: [:breached_password_policy],
    read: :admin,
    admin_columns: [:breached_password_policy, :updated_at],
    system_actions: [read: :accounts]

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
end
