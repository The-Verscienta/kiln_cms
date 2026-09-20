defmodule KilnCMS.CMS.Changes.RederiveOnFocalChange do
  @moduledoc """
  Re-queues `KilnCMS.Media.VariantWorker` when a write moves an image's focal
  point, so the focal-aware `card` crop is re-cut around the new point.

  `KilnCMS.Media.Transform.set_focal_point/4` does this itself for the media
  library's click-to-set; this is the same step for a write that arrives as
  plain attributes (`MediaItem`'s `:update_metadata`, which the JSON:API
  `PATCH` and GraphQL `updateMediaItem` run). Without it an API client could
  move the point and the stored crops would keep centring on the old one.

  Only a raster image has focal-aware crops. A quarantined item (#1122) has
  no public original for the worker to read yet — its strip worker queues
  derivation once it promotes one, and that run reads the new point anyway.
  """
  use Ash.Resource.Change

  alias KilnCMS.MediaKind

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :focal_x) or
         Ash.Changeset.changing_attribute?(changeset, :focal_y) do
      Ash.Changeset.after_action(changeset, fn _changeset, item ->
        rederive(item)
        {:ok, item}
      end)
    else
      changeset
    end
  end

  defp rederive(%{quarantined: true}), do: :ok

  defp rederive(item) do
    if MediaKind.of(item.content_type) == :image do
      %{media_item_id: item.id, org_id: item.org_id}
      |> KilnCMS.Media.VariantWorker.new()
      |> Oban.insert!()
    end

    :ok
  end
end
