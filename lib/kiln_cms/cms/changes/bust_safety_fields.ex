defmodule KilnCMS.CMS.Changes.BustSafetyFields do
  @moduledoc """
  Drops a site's cached safety-field list after any `SiteSafetyFields` write, so
  a save applies to the very next edit instead of waiting out the TTL.

  After the transaction, not after the action, for the reason
  `Changes.BustFeedSettings` gives: a bust sent before the commit lets a reader
  that cannot yet see the write re-cache the old list.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        KilnCMS.Cache.bust_safety_fields(record.org_id)
      end

      result
    end)
  end
end
