defmodule KilnCMS.CMS.Changes.BustLocaleSettings do
  @moduledoc """
  Invalidates what a site's locale fallback chains decide, after any
  `SiteLocaleSettings` write.

  The chains themselves are the small part. Delivery caches the *result* of a
  chain walk under the requested locale's key — a `fr-CA` request that fell
  back to French holds the French record under `fr-CA` — so a chain change
  must also drop the org's cached published records and payloads, or the old
  answer is served until the TTL. Navigation caches a resolved tree per locale
  the same way, and moves by its generation token.

  After COMMIT, for the reason `KilnCMS.CMS.Changes.BustFeedSettings` gives:
  a bust inside the transaction lets a concurrent reader re-cache the pre-save
  chain with a fresh TTL.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &bust/2)
  end

  defp bust(_changeset, {:ok, record} = result) do
    KilnCMS.Cache.bust_locale_fallbacks(record.org_id)
    result
  end

  # A failed write changed nothing, so there is nothing to invalidate.
  defp bust(_changeset, other), do: other
end
