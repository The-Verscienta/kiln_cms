defmodule KilnCMS.CMS.Changes.BustCodeInjection do
  @moduledoc """
  Invalidates a site's cached `%KilnCMS.CodeInjection{}` after any write (#490),
  so a settings save is visible on the next request instead of waiting out the
  TTL.

  This matters more here than for branding: the struct carries the CSP sources
  as well as the HTML, so a stale cache does not merely show the old snippet —
  it serves the *new* snippet under the *old* policy, which is a blocked script
  and a console error rather than a visibly out-of-date page.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # `after_transaction`, not `after_action` — the bust is now a cluster-wide
    # broadcast (#739), and `after_action` runs INSIDE the transaction. A remote
    # node receiving it before the commit deletes its entry, re-reads from a
    # snapshot that does not yet contain the write, and re-caches the OLD
    # snippet under a fresh TTL. That is the exposure this exists to close,
    # reached by a shorter road.
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        KilnCMS.Cache.bust_code_injection(record.org_id)
        # Delivery ETag folds head generation (#1079): injection HTML is in `<head>`.
        KilnCMS.Cache.bump_head_generation(record.org_id)
      end

      result
    end)
  end
end
