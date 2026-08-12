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
    # `after_transaction` for the reason `BustCodeInjection` gives: the branding
    # bust is a cluster-wide broadcast now, and one sent before the commit lets
    # a remote node re-cache the pre-write value under a fresh TTL.
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        KilnCMS.Cache.bust_branding(record.org_id)
        KilnCMS.Cache.bust_llms(record.org_id)
        # Delivery ETag folds head generation (#1079): branding lands in `<head>`.
        KilnCMS.Cache.bump_head_generation(record.org_id)
      end

      result
    end)
  end
end
