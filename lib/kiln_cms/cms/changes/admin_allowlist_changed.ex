defmodule KilnCMS.CMS.Changes.AdminAllowlistChanged do
  @moduledoc """
  After any `KilnCMS.CMS.SiteAdminAllowlist` write commits (#2248): drops the
  compiled list on every node and sets the last-known copy a failed read falls
  back to (the saved list, at its version), then tells the site's open console and sign-in pages, carrying the new
  list compiled, so each judges its own address without re-reading the row
  (`KilnCMSWeb.AdminAllowlist`). A page whose address is no longer admitted
  leaves at once.

  After COMMIT, through `KilnCMS.AfterCommit`, as `SessionPolicyChanged` does: a
  node that re-read before the commit would cache the old list for a minute.
  """
  use Ash.Resource.Change

  alias KilnCMS.Security.AdminAllowlist

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &announce/2)
  end

  defp announce(_changeset, {:ok, record} = result) do
    org_id = record.org_id
    policy = AdminAllowlist.from_row(record)

    KilnCMS.AfterCommit.run(fn ->
      KilnCMS.Cache.bust_admin_allowlist(org_id, AdminAllowlist.last_known(record))

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        AdminAllowlist.topic(org_id),
        {:admin_allowlist_changed, policy}
      )
    end)

    result
  end

  # A failed write changed nothing, so there is nothing to announce.
  defp announce(_changeset, other), do: other
end
