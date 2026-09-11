defmodule KilnCMS.CMS.Changes.BustMediaCache do
  @moduledoc """
  Invalidates the published-content cache (`KilnCMS.Cache`) after a media-item
  write that can affect rendered pages.

  The delivery cache stores blocks with their media already enriched
  (resolved `srcset`/`alt`/dimensions — see `KilnCMSWeb.ContentController`), so a
  change to a media item's alt text, dimensions, variants, storage location
  (`storage_key`/`url`), focal point, decorative flag, content type or audience
  can leave that resolved media stale in any number of cached pages.

  Unlike a content write, a media item has no single `{type, slug}` blast radius —
  it can be referenced by arbitrarily many documents and there's no reverse index
  — so this falls back to a full clear (`Cache.bust_published/0`). Media writes
  that *do* affect rendering (alt-text edits, variant generation, storage
  migration, audience changes, creates/destroys) are infrequent admin/worker
  actions relative to delivery reads, so the blunt clear is an acceptable trade
  for correctness. Attribute-only writes like `download_count` (`:increment_downloads`)
  or translation-only updates must not clear the cache — they would keep it
  permanently cold on a site with a popular download.
  """
  use Ash.Resource.Change

  alias KilnCMS.Cache

  @impl true
  def change(changeset, _opts, _context) do
    # A bulk caller (`KilnCMS.Media.Bulk.delete/2`, the upload loop, the
    # portability importer) sets this to suppress the per-record clear and
    # issue ONE `bust/0` after its loop — without it, creating or deleting N
    # items clears (and lets delivery re-warm) the whole published cache N
    # times for one logical operation. Anything setting this flag owns the
    # single post-loop `bust/0`.
    if changeset.context[:skip_media_cache_bust] do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        bust()
        {:ok, record}
      end)
    end
  end

  @doc """
  What a media write must bust — the single home for that knowledge, called
  by the after_action above and by every `skip_media_cache_bust` caller's
  compensating post-loop clear (so a future change to the invalidation
  strategy lands in one place).
  """
  @spec bust() :: :ok
  def bust do
    Cache.bust_published()
    :ok
  end
end
