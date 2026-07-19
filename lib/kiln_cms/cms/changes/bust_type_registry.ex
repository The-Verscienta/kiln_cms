defmodule KilnCMS.CMS.Changes.BustTypeRegistry do
  @moduledoc """
  Invalidates the cached dynamic-type registry (and the sitemap, whose URL set
  depends on which types exist) after any `TypeDefinition` write — create,
  update (incl. restore), or archive.

  Published payloads of an archived type may linger under their own
  `{name, slug}` cache keys until their short TTL passes; `get_by_path/2`
  stops resolving the type immediately, so only already-cached responses ride
  out the window.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      # The type registry, sitemap and llms.txt are all per-org (#336): bust the
      # writing type's own site so its editors/delivery see the change at once
      # (another org's cached registry is unaffected).
      KilnCMS.Cache.bust_type_registry(record.org_id)
      KilnCMS.Cache.bust_sitemap(record.org_id)
      KilnCMS.Cache.bust_llms(record.org_id)
      {:ok, record}
    end)
  end
end
