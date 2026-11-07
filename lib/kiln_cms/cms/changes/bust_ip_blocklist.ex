defmodule KilnCMS.CMS.Changes.BustIpBlocklist do
  @moduledoc """
  Drops a site's cached IP block rules after a rule is added or removed (#2242),
  on every node.

  `after_transaction` through `KilnCMS.AfterCommit`, for the reason
  `KilnCMS.CMS.Changes.BustCodeInjection` gives: a bust sent before the commit
  lets a reader re-cache the old list for a full TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        KilnCMS.AfterCommit.run(fn -> KilnCMS.Security.IpBlocklist.bust(record.org_id) end)
      end

      result
    end)
  end
end
