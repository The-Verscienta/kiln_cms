defmodule KilnCMS.CMS.SiteSecurityLog do
  @moduledoc """
  How long a site keeps its security audit log (#2241): `security_log_retention_days`,
  default 365, where `0` means keep forever.

  `KilnCMS.Security.retention_days/1` resolves it (this row, else the default)
  and `KilnCMS.Security.PruneWorker` applies it daily.

  One row per organization, created lazily by `:save`, admin-only to read and
  write: the `KilnCMS.CMS.SitePasswordPolicy` shape. There is no `paper_trail`
  history and nothing here is delivered to a visitor. The prune worker reads it
  as `KilnCMS.OrgSettings.system(:security)`; `system_actions:` admits `read`
  and nothing else, so changing the window stays an admin act.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_security_log",
    accept: [:security_log_retention_days],
    read: :admin,
    admin_columns: [:security_log_retention_days, :updated_at],
    system_actions: [read: :security]

  # A century. A bound rather than a policy: it keeps `days * 86_400` and the
  # cutoff arithmetic far from anything absurd.
  @max_days 36_500

  @doc "The retention window a site without a row gets."
  @spec default_days() :: pos_integer()
  def default_days, do: 365

  @doc "The largest accepted value."
  @spec max_days() :: pos_integer()
  def max_days, do: @max_days

  attributes do
    # Days to keep security events; `0` keeps them forever.
    attribute :security_log_retention_days, :integer do
      default 365
      allow_nil? false
      public? true
      constraints min: 0, max: @max_days
    end
  end
end
