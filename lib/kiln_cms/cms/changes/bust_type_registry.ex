defmodule KilnCMS.CMS.Changes.BustTypeRegistry do
  @moduledoc """
  Invalidates the cached dynamic-type registry (and the sitemap, whose URL set
  depends on which types exist) after any `TypeDefinition` write — create,
  update (incl. restore), or archive.

  Published payloads of an archived type may linger under their own
  `{name, slug}` cache keys until their short TTL passes; `get_by_path/1`
  stops resolving the type immediately, so only already-cached responses ride
  out the window.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Cache.bust_type_registry()
      KilnCMS.Cache.bust_sitemap()
      {:ok, record}
    end)
  end
end
