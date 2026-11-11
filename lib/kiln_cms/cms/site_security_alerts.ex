defmodule KilnCMS.CMS.SiteSecurityAlerts do
  @moduledoc """
  A site's security alert settings (#2245), at `/editor/security-alerts`:

    * `disabled_kinds` — the site alert kinds turned off, as strings
      (`KilnCMS.Security.Alerts.site_kinds/0`). Default `["failed_sign_ins"]`:
      every other kind is on. Opt-outs are stored rather than opt-ins, so a
      kind a later release adds starts on; strings rather than atoms, so a row
      written by a newer release still loads after a rollback.
    * `notify_admins` — whether the site's member admins get the bell and the
      email. Default `true`. Off, the site's webhooks still go.
    * `include_full_ip` — whether an alert shows the full client address or
      only its network (`/24`, `/48`). Default `false`.

  None of this reaches the platform's own alerts or the `alerts_silenced`
  notices, which no setting turns off.

  One row per organization, created lazily by `:save`, admin-only to read and
  write: the `KilnCMS.CMS.SiteSecurityLog` shape. The alert delivery reads it as
  `KilnCMS.OrgSettings.system(:security_alerts)`; `system_actions:` admits
  `read` and nothing else, so changing what alerts stays an admin act.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_security_alerts",
    accept: [:disabled_kinds, :notify_admins, :include_full_ip],
    read: :admin,
    admin_columns: [:disabled_kinds, :notify_admins, :include_full_ip, :updated_at],
    system_actions: [read: :security_alerts]

  postgres do
    # An array default the generator cannot render on its own.
    migration_defaults disabled_kinds: ~s(["failed_sign_ins"])
  end

  validations do
    validate KilnCMS.CMS.Validations.SecurityAlertKinds,
      on: [:create, :update],
      where: [action_is([:save, :update])]
  end

  changes do
    # Drop the cached settings on every node once the write commits.
    change KilnCMS.CMS.Changes.SecurityAlertsChanged, on: [:create, :update, :destroy]
    # Turning alerts off is never silent: every write that does sends the
    # site's admins an `alerts_silenced` notice, in the transaction.
    change KilnCMS.Security.Changes.NoticeAlertSettings, on: [:create, :update, :destroy]
  end

  attributes do
    attribute :disabled_kinds, {:array, :string} do
      default ["failed_sign_ins"]
      allow_nil? false
      public? true
      constraints items: [max_length: 64]
    end

    attribute :notify_admins, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :include_full_ip, :boolean do
      default false
      allow_nil? false
      public? true
    end
  end
end
