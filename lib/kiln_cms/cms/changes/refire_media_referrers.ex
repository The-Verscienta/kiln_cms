defmodule KilnCMS.CMS.Changes.RefireMediaReferrers do
  @moduledoc """
  Re-fires the published documents that point at a media item when a write
  changes what its delivered shape (`KilnCMS.Media.Snapshot`) is built from —
  most often `KilnCMS.Media.VariantWorker` recording the variants and
  dimensions it derived after the upload, or a moved focal point.

  A fired `:json` artifact embeds that shape for every `:media` custom field
  and every `image`/`gallery` block, re-read at fire time
  (`Firing.CustomFields`, `Firing.BlockMedia`). Without this an artifact fired
  before the variant worker finished keeps `"variants" => []` until something
  else re-fires it. `KilnCMS.CMS.Changes.BustMediaCache` clears the HTML
  delivery cache for the same writes; artifacts are stored, so they need the
  re-fire.

  The referrers come from the reference graph (`Firing.ReferenceEdge`), which
  records a document's media — featured image, `:media` fields, image and
  gallery blocks — whenever it fires. The wave is `RefireWorker`'s: only
  published documents re-fire, and its `unique` window collapses a burst of
  writes to one job per document. A widely used item (a site logo) costs one
  re-fire per document that shows it — the price of an artifact that is
  self-contained.

  Runs after the write commits, so a rolled-back write re-fires nothing, and a
  re-fire never reads the row before its new values are visible. A bulk caller
  that sets `skip_media_cache_bust` skips this too: those are creates and
  deletes of many items, and nothing references a new item yet.
  """
  use Ash.Resource.Change

  alias KilnCMS.Firing.References
  alias KilnCMS.Media.Snapshot

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      changeset.context[:skip_media_cache_bust] ->
        changeset

      Enum.any?(Snapshot.rendered_fields(), &Ash.Changeset.changing_attribute?(changeset, &1)) ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, item} ->
            References.invalidate(item.org_id, :media, item.id, [])
            {:ok, item}

          _changeset, error ->
            error
        end)

      true ->
        changeset
    end
  end
end
