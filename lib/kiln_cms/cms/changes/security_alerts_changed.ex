defmodule KilnCMS.CMS.Changes.SecurityAlertsChanged do
  @moduledoc """
  After any `KilnCMS.CMS.SiteSecurityAlerts` write commits (#2245): drops the
  site's cached settings on every node, so the failed-sign-in tally
  (`KilnCMS.Security.Alerts.charge_failed_sign_in/2`) starts or stops counting
  at once rather than after the cache's TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} = result ->
        org_id = record.org_id
        KilnCMS.AfterCommit.run(fn -> KilnCMS.Cache.bust_security_alerts(org_id) end)
        result

      _changeset, other ->
        other
    end)
  end
end
