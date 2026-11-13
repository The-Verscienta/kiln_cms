defmodule KilnCMS.Security.PlatformAlertSettings do
  @moduledoc """
  The platform's security alert settings (#2245): which platform alert kinds
  a platform admin turned off. One row for the installation, at
  `/editor/security-alerts` (platform admins only).

    * `disabled_kinds` — the platform kinds turned off, as strings. Only the
      kinds in `KilnCMS.Security.Alerts.platform_optional_kinds/0` may be
      added: today `api_key_rate_limited`, the one platform kind a platform
      admin can turn off (owner decision D-A on #2245, 2026-11-13). Every
      other platform kind is always on. Default `[]`: an opt-out list, so the
      kind starts on, and a kind a later release makes optional starts on too.

  A kind turned off is still recorded in the audit log and still claims its
  alert window; `KilnCMS.Security.Changes.DeliverAlert` stamps it delivered
  and sends nothing.

  Tenant-less and platform-admin only, like `KilnCMS.Mail.Settings`: a site
  admin, the default site's included, can neither read nor write it. The
  delivery reads it as `KilnCMS.Security.alerts_system/0`, admitted to `read`
  and nothing else. Every save is recorded in the instance security log
  (`KilnCMS.Security.InstanceEvent`, `platform_alerts_changed`), which only
  platform admins read: the `alerts_silenced` notice has no platform path
  (it goes to one site's admins).

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_security_alerts"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    # The whole setting, every time: an upsert on the one row.
    create :save do
      accept [:disabled_kinds]
      upsert? true
      upsert_identity :singleton_row
      upsert_fields [:disabled_kinds, :updated_at]

      validate KilnCMS.Security.Validations.PlatformAlertKinds

      change {KilnCMS.Security.Changes.Record,
              type: :platform_alerts_changed,
              scope: :instance,
              mode: :in_transaction,
              target: fn record, _changeset -> {"platform_security_alerts", record.id} end,
              metadata: fn record, _changeset ->
                %{
                  "disabled_kinds" =>
                    KilnCMS.Security.PlatformAlertSettings.disabled_label(record.disabled_kinds)
                }
              end}
    end
  end

  policies do
    # Reading is a platform admin's act (the effective role), and the alert
    # delivery's: `KilnCMS.Security.alerts_system/0`, for `read` alone.
    policy action_type(:read) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
      forbid_unless action(:read)
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :security_alerts}
    end

    # Turning a platform alert off is a platform admin's act alone.
    policy action_type(:create) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    # Constant column backing the unique "there is one row" identity.
    attribute :singleton, :integer do
      allow_nil? false
      default 0
      writable? false
    end

    attribute :disabled_kinds, {:array, :string} do
      default []
      allow_nil? false
      public? true
      constraints items: [max_length: 64]
    end

    timestamps()
  end

  identities do
    identity :singleton_row, [:singleton]
  end

  @doc false
  # The instance log's `disabled_kinds` value: the kinds, or "none".
  @spec disabled_label([String.t()] | nil) :: String.t()
  def disabled_label(kinds) do
    case Enum.sort(kinds || []) do
      [] -> "none"
      kinds -> Enum.join(kinds, ",")
    end
  end
end
