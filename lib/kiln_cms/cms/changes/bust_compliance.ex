defmodule KilnCMS.CMS.Changes.BustCompliance do
  @moduledoc """
  Invalidates a site's resolved claim-checking settings after any
  `KilnCMS.CMS.SiteCompliance` write (#857), so a save is visible in the editor
  on the next keystroke instead of waiting out the TTL.

  This one matters more than the branding equivalent it copies. An admin who
  turns the publish gate **on** and then watches an author ship a flagged claim
  has no way to tell whether the switch worked; an admin who turns it **off** to
  unblock a release watches publishes keep being refused. Both are settings
  whose whole point is that they take effect when you say so.

  ## After the transaction, not after the action

  Ash runs `after_action` hooks *inside* the write transaction. Busting there
  looks right and is worse than not busting at all: between the delete and the
  COMMIT, an editor session resolving its settings misses the cache, reads the
  pre-save row on its own snapshot, and re-caches the old settings with a fresh
  TTL. Nothing busts again, so the admin is told the save succeeded while the
  gate they just turned on stays off for the rest of the TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  defp bust(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_compliance(record.org_id)
    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, other), do: other
end
