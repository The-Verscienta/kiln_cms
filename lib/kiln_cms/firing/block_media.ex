defmodule KilnCMS.Firing.BlockMedia do
  @moduledoc """
  Adds the delivered media shape (`KilnCMS.Media.Snapshot`) to the `:json`
  render of the blocks that show a library item: an `image` block gains a
  `"media"` key, and so does each entry of a `gallery`'s `"images"`. It is the
  same shape a `:media` custom field stores, so an app decodes media one way
  wherever it appears.

  A block's `render/2` is a pure function with no database access, so this
  runs in `KilnCMS.Firing.Engine` after it: one batched read of every item the
  tree names, then a walk of the rendered maps beside the typed blocks they
  came from (a nested `columns` block included). The key is `nil` when the
  block points at no item — a url pasted in, an empty placeholder — or at one
  that no longer exists, so its presence alone says nothing.

  Read at fire time, not stored: a re-fire (which a media change triggers,
  `Changes.RefireMediaReferrers`) carries the item's current variants and focal
  point. `url`/`alt`/`caption` on the block are unchanged — the block's own alt
  still wins over the library's, as it does on every other surface.
  """

  alias KilnCMS.Blocks.{Columns, Gallery, Image}
  alias KilnCMS.Media.Snapshot

  @doc "`rendered` (the `:json` renders of `typed`, in order) with media added."
  @spec put([map() | nil], [struct()], Ash.UUID.t() | nil) :: [map() | nil]
  def put(rendered, typed, org_id) do
    items = Snapshot.load(org_id, ids(typed))
    Enum.zip_with(rendered, typed, &put_block(&1, &2, items))
  end

  defp ids(typed) do
    Enum.flat_map(typed, fn
      %Image{media_id: id} -> [id]
      %Gallery{} = block -> Gallery.media_ids(block)
      %Columns{} = block -> block |> Columns.child_blocks_flat() |> ids()
      _other -> []
    end)
  end

  defp put_block(%{} = json, %Image{media_id: id}, items),
    do: Map.put(json, "media", snapshot(items, id))

  defp put_block(%{"images" => images} = json, %Gallery{}, items) when is_list(images) do
    %{json | "images" => Enum.map(images, &Map.put(&1, "media", snapshot(items, &1["media_id"])))}
  end

  defp put_block(%{"columns" => columns} = json, %Columns{} = block, items)
       when is_list(columns) do
    columns =
      Enum.zip_with(columns, Columns.column_blocks(block), fn
        %{"blocks" => rendered} = column, typed when is_list(rendered) ->
          %{column | "blocks" => Enum.zip_with(rendered, typed, &put_block(&1, &2, items))}

        column, _typed ->
          column
      end)

    %{json | "columns" => columns}
  end

  defp put_block(json, _block, _items), do: json

  defp snapshot(items, id) when is_binary(id) do
    case Map.fetch(items, id) do
      {:ok, item} -> Snapshot.of(item)
      :error -> nil
    end
  end

  defp snapshot(_items, _id), do: nil
end
