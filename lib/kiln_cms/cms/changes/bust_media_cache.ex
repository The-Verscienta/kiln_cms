defmodule KilnCMS.CMS.Changes.BustMediaCache do
  @moduledoc """
  Invalidates the published-content cache (`KilnCMS.Cache`) after a media-item
  write.

  The delivery cache now stores blocks with their media already enriched
  (resolved `srcset`/`alt`/dimensions — see `KilnCMSWeb.ContentController`), so a
  change to a media item (new variants from the processing worker, an alt-text
  edit, a soft-delete/restore) can leave that resolved media stale in any number
  of cached pages.

  Unlike a content write, a media item has no single `{type, slug}` blast radius —
  it can be referenced by arbitrarily many documents and there's no reverse index
  — so this falls back to a full clear (`Cache.bust_published/0`). Media writes
  are infrequent admin/worker actions relative to delivery reads, so the blunt
  clear is an acceptable trade for correctness.
  """
  use Ash.Resource.Change

  alias KilnCMS.Cache

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Cache.bust_published()
      {:ok, record}
    end)
  end
end
