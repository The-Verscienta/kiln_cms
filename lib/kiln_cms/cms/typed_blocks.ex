defmodule KilnCMS.CMS.TypedBlocks do
  @moduledoc """
  Bridge between the legacy `KilnCMS.CMS.Block` storage and the Kiln v2 typed
  block representation (decision D11 / Phase C).

  `from_legacy/1` is the canonical read-direction conversion that firing,
  rendering, search, and embeddings (Phases D–J) use to obtain typed block structs
  from whatever is stored. It is **total** — any legacy/unknown block maps to
  `KilnCMS.Blocks.Custom` so downstream serializers never crash (decision A4).

  `to_legacy/1` is the reverse, kept for the eventual stored-column migration and
  round-trip tests.

  Legacy blocks arrive either as `%KilnCMS.CMS.Block{}` structs (top-level, atom
  keys) or as plain maps with string keys (nested `children` from jsonb), so the
  accessors tolerate both.
  """

  alias KilnCMS.Blocks.{Custom, Divider, Embed, Heading, Image, Quote, RichText}

  @doc "Convert a stored legacy block list into typed block structs."
  @spec from_legacy([struct() | map()] | nil) :: [struct()]
  def from_legacy(blocks) do
    blocks
    |> List.wrap()
    |> Enum.map(&one_from_legacy/1)
  end

  defp one_from_legacy(block) do
    id = get(block, :id)
    type = block |> get(:type) |> to_type()
    content = get(block, :content)
    data = get(block, :data) || %{}

    typed(type, id, content, data, block)
  end

  defp typed(:heading, id, content, data, _block),
    do: %Heading{id: id, _type: "heading", text: content, level: data_int(data, "level", 2)}

  defp typed(:rich_text, id, content, _data, _block) do
    # Stored prose is TipTap HTML/JSON; keep it in legacy_html (the Phase C data
    # migration converts it to canonical Portable Text — decision D12).
    %RichText{id: id, _type: "rich_text", body: [], legacy_html: content}
  end

  defp typed(:image, id, content, data, _block) do
    %Image{
      id: id,
      _type: "image",
      url: data_str(data, "url") || content,
      alt: data_str(data, "alt"),
      caption: data_str(data, "caption")
    }
  end

  defp typed(:quote, id, content, data, _block),
    do: %Quote{id: id, _type: "quote", text: content, citation: data_str(data, "citation")}

  defp typed(:embed, id, content, _data, _block),
    do: %Embed{id: id, _type: "embed", url: content}

  defp typed(:divider, id, _content, _data, _block),
    do: %Divider{id: id, _type: "divider"}

  # columns, custom, and anything unmapped → the total fallback.
  defp typed(other, id, content, data, _block) do
    %Custom{
      id: id,
      _type: "custom",
      legacy_type: to_string(other),
      content: content,
      data: data
    }
  end

  @doc "Best-effort reverse conversion back to legacy block maps."
  @spec to_legacy([struct()] | nil) :: [map()]
  def to_legacy(typed_blocks) do
    typed_blocks
    |> List.wrap()
    |> Enum.map(&one_to_legacy/1)
  end

  defp one_to_legacy(%Heading{} = b),
    do: %{type: :heading, content: b.text, data: %{"level" => b.level}, id: b.id}

  defp one_to_legacy(%RichText{} = b),
    do: %{
      type: :rich_text,
      content: b.legacy_html || KilnCMS.Blocks.PortableText.to_html(b.body),
      data: %{},
      id: b.id
    }

  defp one_to_legacy(%Image{} = b),
    do: %{
      type: :image,
      content: b.url,
      data: %{"url" => b.url, "alt" => b.alt, "caption" => b.caption},
      id: b.id
    }

  defp one_to_legacy(%Quote{} = b),
    do: %{type: :quote, content: b.text, data: %{"citation" => b.citation}, id: b.id}

  defp one_to_legacy(%Embed{} = b), do: %{type: :embed, content: b.url, data: %{}, id: b.id}

  defp one_to_legacy(%Divider{} = b), do: %{type: :divider, content: nil, data: %{}, id: b.id}

  defp one_to_legacy(%Custom{} = b),
    do: %{type: to_type(b.legacy_type), content: b.content, data: b.data || %{}, id: b.id}

  # ── accessors tolerant of struct (atom keys) and jsonb map (string keys) ──
  defp get(block, key), do: Map.get(block, key) || Map.get(block, to_string(key))

  defp to_type(nil), do: :custom
  defp to_type(type) when is_atom(type), do: type

  defp to_type(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> :custom
  end

  # `data` originates from jsonb, so keys are strings.
  defp data_str(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp data_int(data, key, default) do
    case Map.get(data, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  rescue
    ArgumentError -> default
  end
end
