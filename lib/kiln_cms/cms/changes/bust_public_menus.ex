defmodule KilnCMS.CMS.Changes.BustPublicMenus do
  @moduledoc """
  Invalidates a site's cached public navigation trees after any `Menu` or
  `MenuItem` write (#1318), so a menu edit is visible in the delivery
  header/footer on the next request instead of waiting out the TTL.

  One generation bump per write rather than per-key busting: a `MenuItem` knows
  only its `menu_id`, not the menu's key/locale the cache is addressed by, and
  a drag-reorder touches many rows — reading the menu back just to name the key
  would put a query inside every save. The bump is cheap and the org's menus
  are few.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # `after_transaction`, for the reason `BustBranding` gives: the bump is a
    # cluster-wide broadcast, and one sent before the commit lets a remote node
    # re-cache the pre-write tree under the fresh generation.
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, record} <- result do
        KilnCMS.Cache.bump_menus_generation(record.org_id)
        # Delivery ETag folds head generation: the nav lands in every page body.
        KilnCMS.Cache.bump_head_generation(record.org_id)
      end

      result
    end)
  end
end
