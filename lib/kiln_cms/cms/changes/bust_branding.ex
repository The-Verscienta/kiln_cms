defmodule KilnCMS.CMS.Changes.BustBranding do
  @moduledoc """
  Invalidates a site's cached `%KilnCMS.Branding{}` after any `SiteBranding`
  write, so a settings save is visible on the next request instead of waiting
  out the TTL.

  Also busts `llms.txt`, which bakes the site name into its cached *body*.

  The per-record published-content cache is deliberately **not** cleared: it
  holds `%{record, blocks, translations}`, not rendered HTML — the layout
  re-reads branding every request — so a rare settings save must not flush every
  org's content cache.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Cache.bust_branding(record.org_id)
      KilnCMS.Cache.bust_llms(record.org_id)
      {:ok, record}
    end)
  end
end
