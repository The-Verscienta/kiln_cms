defmodule KilnCMS.VisualEditing do
  @moduledoc """
  Visual-editing bridge (#355) — server side.

  Turns a fired `:json` artifact map into an **annotated** one: each addressable
  string value is stega-encoded (see `KilnCMS.VisualEditing.Stega`) with the
  address `%{"type", "id", "field"}` the visual-editing bridge writes back to.
  Document scalars (`title`) address the document `(type, id)`; every block field
  addresses that block's stable `_id` (injected by `KilnCMS.Blocks.render/2`).

  Only leaf **string** content is encoded, and only in preview responses — never
  the public fired artifact. Identifiers and structural keys (`slug`, `url`,
  `_type`, `_id`, `_key`, `layout`, `gap`) are left untouched so the encoding
  can't corrupt a URL, a routing slug, or the block discriminators. Rich-text
  bodies (Portable Text arrays) aren't string leaves, so they're carried through
  unencoded — the bridge addresses them via their block `_id` + `data-kiln-*`
  instead.
  """

  alias KilnCMS.VisualEditing.Stega

  # Keys whose string values must NOT be stega-encoded (identifiers, structure).
  @skip_keys ~w(_type _id _key layout gap url slug)

  @doc "Whether the visual-editing surfaces (annotated read + bridge) are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :visual_editing_enabled, true)

  @doc """
  Stega-annotate a fired `:json` artifact map
  (`%{"type","id","slug","title","blocks"}`) in place. Each encoded payload
  carries everything the bridge needs to act on the value:

    * `type` / `id` / `slug` — the document (write via `PATCH /api/json/<type>/<id>`,
      open the editor at `/editor/site/<type>/<slug>`);
    * `field` — the field name;
    * `block` — the block's stable id for a block field (absent for a document
      scalar like `title`), used as the editor `?focus=` target.

  Returns the map unchanged if it lacks the `type`/`id` address.
  """
  @spec annotate(map()) :: map()
  def annotate(%{"type" => type, "id" => id} = json) when is_binary(type) and not is_nil(id) do
    base = %{"type" => type, "id" => id, "slug" => Map.get(json, "slug")}

    json
    |> encode_field("title", Map.put(base, "field", "title"))
    |> Map.update("blocks", [], fn blocks -> annotate_blocks(blocks, base) end)
  end

  def annotate(json), do: json

  defp annotate_blocks(blocks, base) when is_list(blocks) do
    Enum.map(blocks, &annotate_block(&1, base))
  end

  defp annotate_blocks(other, _base), do: other

  defp annotate_block(%{} = block, base) do
    block_id = block["_id"]

    Map.new(block, fn
      # Recurse into nested containers (e.g. the `columns` block).
      {"columns", cols} when is_list(cols) ->
        {"columns", Enum.map(cols, &annotate_column(&1, base))}

      {"blocks", children} when is_list(children) ->
        {"blocks", annotate_blocks(children, base)}

      {k, v} when is_binary(v) and k not in @skip_keys and not is_nil(block_id) ->
        {k, Stega.encode(v, Map.merge(base, %{"field" => k, "block" => block_id}))}

      pair ->
        pair
    end)
  end

  defp annotate_block(other, _base), do: other

  defp annotate_column(%{"blocks" => children} = col, base) do
    %{col | "blocks" => annotate_blocks(children, base)}
  end

  defp annotate_column(other, _base), do: other

  defp encode_field(map, key, payload) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> Map.put(map, key, Stega.encode(v, payload))
      _ -> map
    end
  end
end
