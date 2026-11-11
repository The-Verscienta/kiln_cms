defmodule KilnCMS.Security.Changes.RecordOrgSetting do
  @moduledoc """
  The audit event (#2241) of a site-level setting being changed, declared once
  in the `KilnCMS.CMS.OrgSettings` macro so every one-row-per-org settings
  resource (mail relay, storage, code injection, password policy, the security
  log's own retention...) is covered by one choke point, and a new one cannot
  forget it. Also used by `KilnCMS.CMS.SiteSsoDomain`.

  Options:

    * `:type` - `:org_setting_changed` (default) or `:sso_config_changed`.
    * `:provider` - with `:sso_config_changed`, the `provider` metadata value.

  What is recorded:

    * `:org_setting_changed` - `setting` is the resource's short name
      (`"site_mail_relay"`) and nothing else: **no value, old or new**, so a
      secret in a setting cannot reach the log.
    * `:sso_config_changed` - `provider` and `change`, which is `created`,
      `updated` or `removed` from the action's type. Never the issuer, client
      id, client secret or a domain.

  Only a person's write is an audit event. A system write (the VAPID key
  generated on first use, a federation sync, a seed) has no actor to attribute
  and is not a decision anyone took, so it is left out. Written in the
  transaction, so the event commits or rolls back with the setting. An upsert
  `:save` reads as `created`, even when it landed on an existing row.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, opts, context) do
    type = Keyword.get(opts, :type, :org_setting_changed)

    Record.change(
      changeset,
      [
        type: type,
        when: fn _record, changeset -> match?(%User{}, changeset.context[:private][:actor]) end,
        target: fn record, changeset ->
          {changeset.resource |> short_name(), Map.get(record, :id)}
        end,
        metadata: fn _record, changeset -> metadata(type, opts, changeset) end
      ],
      context
    )
  end

  defp metadata(:sso_config_changed, opts, changeset) do
    %{"provider" => Keyword.fetch!(opts, :provider), "change" => change_name(changeset)}
  end

  defp metadata(_type, _opts, changeset), do: %{"setting" => short_name(changeset.resource)}

  defp change_name(%{action: %{type: :create}}), do: "created"
  defp change_name(%{action: %{type: :update}}), do: "updated"
  defp change_name(%{action: %{type: :destroy}}), do: "removed"

  defp short_name(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore()
  end
end
