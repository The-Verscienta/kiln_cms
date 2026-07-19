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
      # The type registry is global (TypeDefinition isn't org-scoped yet); the
      # sitemap/llms are per-org (#336). With the single-org rollout guard in
      # force, bust the default org's copies. Revisit (bust every org) when
      # TypeDefinition becomes tenant-scoped.
      KilnCMS.Cache.bust_type_registry()
      KilnCMS.Cache.bust_sitemap(KilnCMS.Accounts.default_org_id())
      KilnCMS.Cache.bust_llms(KilnCMS.Accounts.default_org_id())
      {:ok, record}
    end)
  end
end
