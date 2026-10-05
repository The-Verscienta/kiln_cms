defmodule KilnCMS.CMS.Changes.BustSecurityTxt do
  @moduledoc """
  Drops a site's cached `security.txt` (`KilnCMS.SecurityTxt.resolve/1`) after
  any `SiteSecurityTxt` write, so a changed contact is served on the next
  request rather than after the TTL.

  After COMMIT, for the reason `KilnCMS.CMS.Changes.BustFeedSettings` gives:
  a bust inside the transaction lets a concurrent reader re-cache the pre-save
  row with a fresh TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  defp bust(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_security_txt(record.org_id)
    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, other), do: other
end
