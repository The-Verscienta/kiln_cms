defmodule KilnCMS.Security.Changes.NoticeAlertSettings do
  @moduledoc """
  The `alerts_silenced` notice (#2245) of a `KilnCMS.CMS.SiteSecurityAlerts`
  write that makes the site's alerts quieter, on `:save`, `:update` and
  `:destroy`:

    * a kind newly turned off → `kind_disabled`, naming the kinds;
    * `notify_admins` turned off → `admin_notifications_off`.

  A reset (`:destroy`) is compared with the defaults it falls back to, so
  resetting a site that had `failed_sign_ins` on turns it off and says so.
  Turning things back on, and `include_full_ip`, raise nothing.

  The row as it was is read **before** the write, locked
  (`FOR UPDATE`), as `KilnCMS.OrgSettings.system(:security_alerts)` with
  `authorize_with: :error`: two concurrent saves are compared one after the
  other, and a read that is refused fails the save rather than compare
  against nothing. The notice is written in the save's transaction
  (`KilnCMS.Security.AlertGate.insert_notice!/2`) and fails closed: a notice
  that cannot be written rolls the save back.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.AlertGate
  alias KilnCMS.Security.Alerts

  @before_key :security_alert_settings_before

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.set_context(changeset, %{@before_key => current(changeset)})
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      before = Map.fetch!(changeset.context, @before_key)

      after_write =
        if changeset.action_type == :destroy, do: Alerts.defaults(), else: effective(record)

      # The row's own org: the tenant may be an `Organization` struct (the
      # console passes `current_org`), and the notice is keyed on the id.
      org_id = record.org_id

      for notice <- notices(before, after_write) do
        AlertGate.insert_notice!(org_id, Map.put(notice, :actor_id, actor_id(changeset)))
      end

      {:ok, record}
    end)
  end

  defp current(changeset) do
    query = Ash.Query.lock(KilnCMS.CMS.SiteSecurityAlerts, :for_update)

    case KilnCMS.CMS.list_site_security_alerts!(
           query: query,
           tenant: changeset.tenant,
           actor: KilnCMS.OrgSettings.system(:security_alerts),
           authorize_with: :error
         ) do
      [row | _] -> effective(row)
      [] -> Alerts.defaults()
    end
  end

  defp effective(row) do
    %{
      disabled_kinds: row.disabled_kinds || [],
      notify_admins: row.notify_admins,
      include_full_ip: row.include_full_ip
    }
  end

  @doc false
  # The notices a change from `before` to `after_write` raises.
  @spec notices(Alerts.settings(), Alerts.settings()) :: [map()]
  def notices(before, after_write) do
    newly_disabled = Enum.uniq(after_write.disabled_kinds -- before.disabled_kinds)

    kinds =
      if newly_disabled == [],
        do: [],
        else: [%{change: "kind_disabled", kinds: Enum.sort(newly_disabled)}]

    notify =
      if before.notify_admins != false and after_write.notify_admins == false,
        do: [%{change: "admin_notifications_off"}],
        else: []

    kinds ++ notify
  end

  defp actor_id(changeset) do
    case changeset.context[:private][:actor] do
      %User{id: id} -> id
      _other -> nil
    end
  end
end
