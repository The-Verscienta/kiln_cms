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
  alias KilnCMS.HTMLSanitizer

  @block_modules [Heading, Image, RichText, Quote, Embed, Divider, Custom]

  @doc """
  Normalize any block representation to typed block structs.

  Handles legacy maps/structs, typed maps (`_type`), typed structs, and the
  `%Ash.Union{}` wrapper produced once `blocks` is stored as `BlockUnion`. This is
  what firing/search/history/delivery call so they are agnostic to how a block was
  obtained.
  """
  @spec to_typed([term()] | nil) :: [struct()]
  def to_typed(blocks), do: blocks |> List.wrap() |> Enum.map(&one_to_typed/1)

  defp one_to_typed(%Ash.Union{value: value}), do: one_to_typed(value)
  defp one_to_typed(%mod{} = struct) when mod in @block_modules, do: struct
  defp one_to_typed(%{} = map), do: one_from_typed_or_legacy(map)
  defp one_to_typed(_other), do: %Custom{_type: "custom", data: %{}}

  defp one_from_typed_or_legacy(map) do
    if typed_map?(map), do: struct_from_typed_map(map), else: one_from_legacy(map)
  end

  # ── BlockUnion cast normalization (legacy/stored-shape tolerance) ──────────
  # These keep `BlockUnion` accepting legacy block params (no test churn) and
  # legacy stored rows (lazy conversion, no data migration).

  @doc false
  # cast_input target: a tag-shaped map (`%{"_type" => name, ...attrs}`) the union
  # matches by its `_type` tag. Everything is sanitized (this is user input).
  def to_union_input(nil), do: nil

  def to_union_input(value) do
    case typed_attrs(value) do
      {nil, _attrs} -> value
      {name, attrs} -> attrs |> Map.put("_type", name) |> sanitize_attrs() |> drop_nils()
    end
  end

  @doc false
  # cast_stored target: the `:type_and_value` envelope (`%{"type" => name,
  # "value" => attrs}`). Stored data is already sanitized, so we don't re-sanitize.
  def to_union_stored(nil), do: nil

  def to_union_stored(value) do
    if stored_envelope?(value) do
      value
    else
      case typed_attrs(value) do
        {nil, _attrs} -> value
        {name, attrs} -> %{"type" => name, "value" => drop_nils(attrs)}
      end
    end
  end

  defp drop_nils(%{} = map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  # Returns {type_name :: String.t() | nil, attrs :: %{String.t() => term()}}.
  defp typed_attrs(%Ash.Union{type: type, value: %_{} = value}),
    do: {to_string(type), attrs_of(value)}

  defp typed_attrs(%mod{} = struct) when mod in @block_modules,
    do: {struct._type, attrs_of(struct)}

  defp typed_attrs(%mod{} = struct) when mod == KilnCMS.CMS.Block,
    do: struct |> one_from_legacy() |> typed_attrs()

  defp typed_attrs(%{} = map) do
    cond do
      typed_map?(map) -> {to_string(get(map, :_type)), stringify(map)}
      stored_envelope?(map) -> {to_string(get(map, :type)), stringify(get(map, :value))}
      legacy_map?(map) -> map |> one_from_legacy() |> typed_attrs()
      true -> {nil, map}
    end
  end

  defp typed_attrs(_other), do: {nil, %{}}

  defp attrs_of(%mod{} = struct) do
    keys = [:id, :_type, :_version | Enum.map(Kiln.Block.Info.fields(mod), & &1.name)]
    Map.new(keys, fn key -> {to_string(key), Map.get(struct, key)} end)
  end

  defp typed_map?(map), do: not is_nil(get(map, :_type))

  defp stored_envelope?(%{} = map),
    do: not is_nil(get(map, :value)) and not is_nil(get(map, :type))

  defp stored_envelope?(_), do: false

  defp legacy_map?(%{} = map), do: not is_nil(get(map, :type))

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp sanitize_attrs(%{"_type" => "rich_text"} = m) do
    m
    |> Map.update("legacy_html", nil, &HTMLSanitizer.sanitize_rich_text/1)
    |> Map.update("body", nil, &KilnCMS.Blocks.PortableText.sanitize_body/1)
  end

  defp sanitize_attrs(%{"_type" => "image"} = m),
    do: Map.update(m, "url", nil, &(HTMLSanitizer.safe_image_src(&1) || ""))

  defp sanitize_attrs(%{"_type" => "embed"} = m),
    do: Map.update(m, "url", nil, &(HTMLSanitizer.safe_embed_url(&1) || ""))

  defp sanitize_attrs(m), do: m

  # Build a typed struct from a typed map (string or atom keys), upcasting first.
  defp struct_from_typed_map(map) do
    map = map |> stringify() |> KilnCMS.Blocks.Upcaster.upcast_block_map()

    case KilnCMS.Blocks.fetch(block_type_atom(map)) do
      {:ok, mod} ->
        struct(mod, typed_struct_kv(mod, map))

      :error ->
        %Custom{_type: "custom", content: get(map, :content), data: get(map, :data) || %{}}
    end
  end

  @type_atoms %{
    "heading" => :heading,
    "image" => :image,
    "rich_text" => :rich_text,
    "quote" => :quote,
    "embed" => :embed,
    "divider" => :divider,
    "custom" => :custom
  }
  defp block_type_atom(map), do: Map.get(@type_atoms, to_string(get(map, :_type)), :custom)

  defp typed_struct_kv(mod, map) do
    keys = [:id, :_type, :_version | Enum.map(Kiln.Block.Info.fields(mod), & &1.name)]
    Enum.flat_map(keys, fn key -> kv_for(map, key) end)
  end

  defp kv_for(map, key) do
    case Map.get(map, to_string(key)) do
      nil -> []
      value -> [{key, value}]
    end
  end

  @doc """
  A typed block (struct or `%Ash.Union{}`) as a string-keyed input map — the
  shape `BlockUnion.cast_input` accepts. Used by callers that rebuild a
  record's `blocks` param from its current value with targeted edits (e.g.
  the collab checkpoint materializer replacing one block's `legacy_html`).
  """
  @spec input_map(struct() | Ash.Union.t()) :: %{String.t() => term()}
  def input_map(%Ash.Union{value: value}), do: input_map(value)
  def input_map(%_{} = struct), do: struct |> attrs_of() |> drop_nils()

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
      caption: data_str(data, "caption"),
      media_id: data_str(data, "media_id")
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
      data: %{"url" => b.url, "alt" => b.alt, "caption" => b.caption, "media_id" => b.media_id},
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
