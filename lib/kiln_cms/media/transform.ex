defmodule KilnCMS.Media.Transform do
  @moduledoc """
  In-admin image editing: rotate/flip a `MediaItem`'s original, or move its
  **focal point**, and regenerate the derivative pipeline.

  Edits are written under a **new storage key** — the previous original is
  deliberately left in place, because published content embeds media
  snapshots (`%{"id", "url", …}`) captured at write time and fired artifacts
  keep serving the old URL until their content is re-published. The item's
  `url`/`storage_key`/dimensions move to the edited copy, the focal point is
  carried through the geometry (a rotate rotates it too), and the
  `VariantWorker` re-derives thumbnails and focal-aware crops from the new
  original.
  """

  alias KilnCMS.{CMS, ImageProcessor, Storage}
  alias KilnCMS.Media.VariantWorker

  @type op :: :rotate_left | :rotate_right | :flip_horizontal | :flip_vertical

  @doc """
  Apply a geometric edit to `item`'s original and update the item (new
  URL/key/dimensions + transformed focal point), then re-enqueue variant
  generation. Returns the updated item; `{:error, _}` when the original
  isn't fetchable or isn't a processable raster image.
  """
  @spec apply(struct(), op(), keyword()) :: {:ok, struct()} | {:error, term()}
  def apply(item, op, opts \\ []) do
    ext = Path.extname(item.storage_key || "")

    with {:ok, binary} <- Storage.fetch(item.storage_key),
         tmp = write_temp(binary, ext),
         {:ok, edited} <- transform_temp(tmp, ext, op),
         {:ok, key} <- store_edited(edited.path, ext) do
      {focal_x, focal_y} = transform_focal(item.focal_x || 0.5, item.focal_y || 0.5, op)

      result =
        CMS.update_media_item(
          item,
          %{
            storage_key: key,
            url: Storage.url(key),
            width: edited.width,
            height: edited.height,
            focal_x: focal_x,
            focal_y: focal_y
          },
          opts
        )

      with {:ok, updated} <- result do
        enqueue_variants(updated)
        {:ok, updated}
      end
    end
  end

  @doc """
  Move `item`'s focal point (fractions of width/height, clamped to 0..1) and
  regenerate the focal-aware crops around it.
  """
  @spec set_focal_point(struct(), number(), number(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def set_focal_point(item, x, y, opts \\ []) do
    result =
      CMS.update_media_item(
        item,
        %{focal_x: clamp(x), focal_y: clamp(y)},
        opts
      )

    with {:ok, updated} <- result do
      enqueue_variants(updated)
      {:ok, updated}
    end
  end

  # Rotating/flipping the pixels moves the subject: carry the focal point
  # through the same geometry.
  defp transform_focal(x, y, :rotate_right), do: {1.0 - y, x}
  defp transform_focal(x, y, :rotate_left), do: {y, 1.0 - x}
  defp transform_focal(x, y, :flip_horizontal), do: {1.0 - x, y}
  defp transform_focal(x, y, :flip_vertical), do: {x, 1.0 - y}

  defp clamp(value), do: (value / 1) |> max(0.0) |> min(1.0)

  defp transform_temp(tmp, ext, op) do
    ImageProcessor.transform(tmp, ext, op)
  after
    rm(tmp)
  end

  defp store_edited(path, ext) do
    key = Storage.generate_key("edited#{ext}")

    case Storage.store(key, path) do
      {:ok, ^key} -> {:ok, key}
      error -> error
    end
  after
    rm(path)
  end

  defp enqueue_variants(item) do
    %{media_item_id: item.id} |> VariantWorker.new() |> Oban.insert!()
  end

  # Paths are server-built temp files (System.tmp_dir! + UUID), never user
  # input — the traversal warnings are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp(binary, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-edit-#{Ecto.UUID.generate()}#{ext}")
    File.write!(tmp, binary)
    tmp
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)
end
