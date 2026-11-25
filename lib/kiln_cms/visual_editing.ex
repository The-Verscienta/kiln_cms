defmodule KilnCMS.VisualEditing do
  @moduledoc """
  Visual-editing bridge (#355) — server side.

  Turns a fired `:json` artifact map into an **annotated** one: each addressable
  string value is stega-encoded (see `KilnCMS.VisualEditing.Stega`) with the
  address `%{"type", "id", "field"}` the visual-editing bridge writes back to.
  Document scalars (`title`) address the document `(type, id)`; every block field
  addresses that block's stable `_id` (injected by `KilnCMS.Blocks.render/2`).

  Only **prose** is encoded, and only in preview responses — never the public
  fired artifact. A front end uses most other strings as they are, so an
  invisible tail on them breaks it: a video's `src`, a file's `download_url` or
  an embed's `resolved_url` would 404, and a `media_id` or `form_slug` would
  match nothing (#2770). So encoding is an **allowlist**, not a skip list:

    * a block field is encoded only when its block type declares it plain-text
      translatable (`Kiln.Block.Info.translatable/1` says `:text`). Fields that
      say `translatable: false` (URLs, media ids, filenames, layout keys) and
      keys the renderer derives (`src`, `poster`, `captions_url`,
      `download_url`, `_id`, `_type`) are never encoded. A plugin block follows
      its own declaration; a block whose type isn't registered is left as is;
    * on top of that, a value that reads as a URL, a path, a UUID, JSON or an
      identifier-like token (no spaces, with `_`, `/` or an inner `.`) is never
      encoded, so a plugin string field that holds a URL but forgot
      `translatable: false` still comes through intact. Custom fields, which
      carry no schema here, rely on this check alone.

  The document `title` is always prose. Rich-text bodies (Portable Text
  arrays) aren't string leaves: each span's text is encoded instead.
  """

  alias Kiln.Block.Info
  alias KilnCMS.VisualEditing.Stega

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  # `scheme:` with no space after it: `https://…`, `mailto:a@b`, `data:…`.
  @scheme ~r/\A[a-z][a-z0-9+.-]*:\S/i
  # One token joined by `_`, `/` or an inner `.`: `video/mp4`, `report.pdf`,
  # `contact_form`, `example.com`.
  @identifier ~r/\A\S*(?:_|\/|\w\.\w)\S*\z/u

  @doc "Whether the visual-editing surfaces (annotated preview + bridge) are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :visual_editing_enabled, true)

  @doc """
  Stega-annotate a fired `:json` artifact map
  (`%{"type","id","slug","locale","title","blocks"}`) in place. Each encoded
  payload carries everything the bridge needs to act on the value:

    * `type` / `id` / `slug` / `locale` — the document (write via
      `PATCH /api/json/<type>/<id>`, open the editor at
      `/editor/site/<type>/<slug>?locale=<locale>`);
    * `field` — the field name;
    * `block` — the block's stable id for a block field (absent for a document
      scalar like `title`), used as the editor `?focus=` target.

  Returns the map unchanged if it lacks the `type`/`id` address.
  """
  @spec annotate(map()) :: map()
  def annotate(%{"type" => type, "id" => id} = json) when is_binary(type) and not is_nil(id) do
    base =
      %{"type" => type, "id" => id, "slug" => Map.get(json, "slug")}
      |> maybe_put_locale(Map.get(json, "locale"))

    prose = prose_keys()

    json
    |> encode_field("title", Map.put(base, "field", "title"))
    |> Map.update("blocks", [], fn blocks -> annotate_blocks(blocks, base, prose) end)
    |> annotate_custom_fields(base)
  end

  def annotate(json), do: json

  defp maybe_put_locale(base, locale) when is_binary(locale) and locale != "",
    do: Map.put(base, "locale", locale)

  defp maybe_put_locale(base, _locale), do: base

  # Custom fields (present on the annotated preview, not the public artifact):
  # each plain-string value is stega-encoded with `{type, id, slug, field}` —
  # no `block`, so the bridge deep-links these to the structured editor's
  # field-level `?focus=` (#442). Values consumers parse or use as they are
  # stay untouched (`prose_value?/1`): JSON-encoded structures (a common
  # importer convention for structured custom fields), URLs and paths, UUIDs
  # and identifier-like tokens, where an invisible tail would corrupt
  # `JSON.parse`, an `src`/`href` or a lookup. Non-string values pass through.
  defp annotate_custom_fields(%{"custom_fields" => cf} = json, base) when is_map(cf) do
    %{
      json
      | "custom_fields" =>
          Map.new(cf, fn
            {name, value} when is_binary(value) ->
              if prose_value?(value) do
                {name, Stega.encode(value, Map.put(base, "field", name))}
              else
                {name, value}
              end

            pair ->
              pair
          end)
    }
  end

  defp annotate_custom_fields(json, _base), do: json

  # Whether a string reads as prose a person wrote, rather than a value a
  # front end parses or uses as is. The guard behind the block allowlist (it
  # keeps a URL in a plugin field that forgot `translatable: false`
  # byte-for-byte) and the only check custom fields get.
  defp prose_value?(value) do
    trimmed = String.trim(value)

    trimmed != "" and
      not String.starts_with?(trimmed, ["{", "[", "/", "./", "../", "#", "?"]) and
      not Regex.match?(@uuid, trimmed) and
      not Regex.match?(@scheme, trimmed) and
      not Regex.match?(@identifier, trimmed)
  end

  # `_type` → the block fields that hold plain prose, for every registered
  # block, core and plugin. Built once per `annotate/1` call rather than per
  # block.
  defp prose_keys do
    Map.new(KilnCMS.Blocks.modules(), fn module ->
      keys = for {name, :text} <- Info.translatable(module), do: Atom.to_string(name)
      {Atom.to_string(Info.name(module)), keys}
    end)
  end

  defp annotate_blocks(blocks, base, prose) when is_list(blocks) do
    Enum.map(blocks, &annotate_block(&1, base, prose))
  end

  defp annotate_blocks(other, _base, _prose), do: other

  defp annotate_block(%{} = block, base, prose) do
    block_id = block["_id"]
    prose_keys = Map.get(prose, block["_type"], [])

    Map.new(block, fn
      # Recurse into nested containers (e.g. the `columns` block).
      {"columns", cols} when is_list(cols) ->
        {"columns", Enum.map(cols, &annotate_column(&1, base, prose))}

      {"blocks", children} when is_list(children) ->
        {"blocks", annotate_blocks(children, base, prose)}

      # Rich-text `body` is a Portable Text array (not a string leaf), so encode
      # into each span's text — every rendered word carries the block address, so
      # a click anywhere in the rich text resolves to this block (#355).
      {"body", body} when is_list(body) and not is_nil(block_id) ->
        {"body",
         annotate_portable_text(body, Map.merge(base, %{"field" => "body", "block" => block_id}))}

      # Only a field its block type declares as prose (see the moduledoc).
      {k, v} when is_binary(v) and not is_nil(block_id) ->
        if k in prose_keys and prose_value?(v) do
          {k, Stega.encode(v, Map.merge(base, %{"field" => k, "block" => block_id}))}
        else
          {k, v}
        end

      pair ->
        pair
    end)
  end

  defp annotate_block(other, _base, _prose), do: other

  # Walk a Portable Text body (`[%{"children" => [spans]}]`) and stega-encode each
  # span's text. Spans have no stable key, so the address is block-level (the edit
  # round-trip opens the whole rich-text block) — the per-span encoding just makes
  # every rendered word clickable. Two deliberate exceptions:
  #   * code blocks stay clean — invisible tag characters inside code would
  #     corrupt client-side highlighting and copy-paste;
  #   * table items (#475) keep their spans two levels down (rows[].cells[]),
  #     so they get their own walk instead of the top-level `children` match.
  defp annotate_portable_text(body, payload) do
    Enum.map(body, fn
      %{"style" => "code"} = pt_block ->
        pt_block

      %{"_type" => "table"} = pt_block ->
        annotate_table(pt_block, payload)

      %{"children" => children} = pt_block when is_list(children) ->
        %{pt_block | "children" => Enum.map(children, &annotate_span(&1, payload))}

      other ->
        other
    end)
  end

  defp annotate_table(pt_block, payload) do
    rows =
      pt_block["rows"]
      |> List.wrap()
      |> Enum.map(fn
        %{"cells" => cells} = row when is_list(cells) ->
          %{row | "cells" => Enum.map(cells, &annotate_cell(&1, payload))}

        row ->
          row
      end)

    Map.put(pt_block, "rows", rows)
  end

  defp annotate_cell(%{"children" => children} = cell, payload) when is_list(children),
    do: %{cell | "children" => Enum.map(children, &annotate_span(&1, payload))}

  defp annotate_cell(cell, _payload), do: cell

  defp annotate_span(%{"_type" => "span", "text" => text} = span, payload)
       when is_binary(text) and text != "" do
    %{span | "text" => Stega.encode(text, payload)}
  end

  defp annotate_span(other, _payload), do: other

  defp annotate_column(%{"blocks" => children} = col, base, prose) do
    %{col | "blocks" => annotate_blocks(children, base, prose)}
  end

  defp annotate_column(other, _base, _prose), do: other

  defp encode_field(map, key, payload) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> Map.put(map, key, Stega.encode(v, payload))
      _ -> map
    end
  end
end
