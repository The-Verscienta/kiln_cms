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

  alias KilnCMS.Blocks.{Accordion, Claim, Columns, Custom, Divider, Embed, Faq, Form}
  alias KilnCMS.Blocks.{Gallery, Heading, HowTo, Image, Quote, RichText}
  alias KilnCMS.HTMLSanitizer

  # Guards recursion for the nested `columns` block: hostile API input can't force
  # unbounded nesting on cast (columns nested past this depth are dropped). The
  # editor caps nesting well below this, so real content is never affected.
  @max_nesting 5

  # Every block module in the storage union — core + plugin (D18), from the
  # same compile-time source as `BlockUnion` itself.
  @block_modules Enum.map(KilnCMS.Blocks.union_types(), fn {_name, opts} -> opts[:type] end)

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

  # An `Ash.Union` that has been through JSON — `%{"type" => tag, "value" => …}`
  # — which is how a union lands in a paper-trail version's freeform `changes`
  # map. Without this clause it misses `typed_map?/1` (the `_type` tag is one
  # level down), falls through to the legacy branch, and every block in a
  # replayed document comes back as `Custom` (#917).
  #
  # That is why a point-in-time read rendered a bare `<!-- fragment block -->`:
  # `Fragments.expand/3` never saw a `%Fragment{}` to expand. It was mis-typing
  # every OTHER block the same way, silently, since replay existed.
  #
  # `map_size/1` pins the shape: the serialized union has exactly these two
  # keys, while a legacy block carries its kind in `"type"` alongside its own
  # attributes, so a bare size check is what keeps the two apart.
  defp one_to_typed(%{"type" => _tag, "value" => %{} = value} = map) when map_size(map) == 2,
    do: one_to_typed(value)

  defp one_to_typed(%mod{} = struct) when mod in @block_modules, do: struct
  defp one_to_typed(%{} = map), do: one_from_typed_or_legacy(map)
  defp one_to_typed(_other), do: %Custom{_type: "custom", data: %{}}

  defp one_from_typed_or_legacy(map) do
    map = normalize_rich_text_map(map)
    if typed_map?(map), do: struct_from_typed_map(map), else: one_from_legacy(map)
  end

  # The editor's form carries `body` as a JSON string of the live TipTap doc;
  # normalize it here too (not only in the cast) so the in-editor preview —
  # which routes unsaved form values through `to_typed/1` — renders the prose
  # being typed rather than falling back to an empty legacy_html.
  defp normalize_rich_text_map(%{} = map) do
    if (map["_type"] || map[:_type]) in ["rich_text", :rich_text] do
      cond do
        Map.has_key?(map, "body") -> Map.update!(map, "body", &normalize_body/1)
        Map.has_key?(map, :body) -> Map.update!(map, :body, &normalize_body/1)
        true -> map
      end
    else
      map
    end
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
    m = Map.update(m, "body", nil, &normalize_body/1)

    case m["body"] do
      [_ | _] ->
        # Portable Text is authoritative once present: the editor writes body
        # (TipTap JSON, converted above), so a stale legacy_html copy must not
        # shadow it in render fallbacks or linger as a second source of truth.
        m
        |> Map.put("legacy_html", nil)
        |> Map.update("body", nil, &KilnCMS.Blocks.PortableText.sanitize_body/1)

      _ ->
        m
        |> Map.update("legacy_html", nil, &HTMLSanitizer.sanitize_rich_text/1)
        |> Map.update("body", nil, &KilnCMS.Blocks.PortableText.sanitize_body/1)
    end
  end

  defp sanitize_attrs(%{"_type" => "image"} = m),
    do: Map.update(m, "url", nil, &(HTMLSanitizer.safe_image_src(&1) || ""))

  # Keeps the author's URL rather than rewriting it to a player URL (#489).
  #
  # This used to run `safe_embed_url/1`, which knows two hosts and rewrites
  # them — so a stored embed URL was a canonical YouTube/Vimeo player URL or the
  # empty string, and everything else an author pasted was destroyed on save.
  # Whether a URL may be *framed* is a render-time question both surfaces
  # already ask; making it the storage filter as well meant nothing downstream
  # could ever see what was actually embedded.
  #
  # The metadata fields are resolved server-side, but they are ordinary block
  # scalars — the editor's generic field renderer offers them as inputs and a
  # headless `block_tree` write can set them directly — so they are filtered
  # here on the same footing as anything else an author can type. In particular
  # `thumbnail_url` becomes an `<img src>`: without this, "checked against the
  # provider's CDN when it was resolved" would be true only of values that
  # actually came from a resolve.
  defp sanitize_attrs(%{"_type" => "embed"} = m) do
    m
    |> Map.update("url", nil, &(HTMLSanitizer.safe_external_url(&1) || ""))
    |> Map.update("thumbnail_url", nil, &KilnCMS.OEmbed.allowed_thumbnail(&1))
  end

  # A `gallery`'s urls live one level down, inside an `{:array, :map}` field, so
  # the `image` clause above never sees them. Without this a gallery item is the
  # one image url on the write path that reaches storage unfiltered — a
  # `javascript:` src straight through to delivery (#482).
  defp sanitize_attrs(%{"_type" => "gallery"} = m) do
    Map.update(m, "images", [], fn
      images when is_list(images) -> Enum.map(images, &sanitize_gallery_image/1)
      _other -> []
    end)
  end

  # A `columns` container: sanitize each child block through the same typed-input
  # pipeline a top-level block uses, so nested rich_text/image/embed are cleaned.
  defp sanitize_attrs(%{"_type" => "columns"} = m), do: sanitize_columns_block(m, 1)

  defp sanitize_attrs(m), do: m

  # String-keyed and url-filtered, whatever shape came in.
  #
  # Keys are normalized first because atom-keyed image maps are a real input —
  # seeds, in-Elixir importers and plugins all produce them, and
  # `KilnCMS.Blocks.Gallery.images/1` deliberately reads either. Updating only
  # the `"url"` key would leave an atom-keyed `:url` untouched *and* insert a
  # nil `"url"` beside it, so the unfiltered value is the one that wins on read
  # — reaching the fired JSON artifact, which is precisely the consumer the
  # sanitizer exists for (the HTML paths re-filter on the way out; JSON does
  # not).
  defp sanitize_gallery_image(image) when is_map(image) do
    image
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("url", "", fn
      url when is_binary(url) -> HTMLSanitizer.safe_image_src(url) || ""
      # A number or an object is not a url. Blanking it keeps a malformed API
      # write a no-op rather than a `FunctionClauseError` 500 out of cast.
      _other -> ""
    end)
  end

  defp sanitize_gallery_image(other), do: other

  # The editor's hidden input posts body as a JSON string of the live TipTap
  # document; the API/imports post decoded Portable Text. Normalize all input
  # shapes to a PT list: JSON strings are decoded, a TipTap doc is converted
  # (PortableText.from_tiptap/1), a PT list passes through.
  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize_body(decoded)
      _ -> []
    end
  end

  defp normalize_body(%{"type" => "doc"} = doc), do: KilnCMS.Blocks.PortableText.from_tiptap(doc)
  defp normalize_body(body) when is_list(body), do: body
  defp normalize_body(_), do: []

  defp sanitize_columns_block(m, depth) do
    Map.update(m, "columns", [], fn cols ->
      cols
      |> List.wrap()
      |> Enum.map(fn
        %{} = col -> Map.update(col, "blocks", [], &sanitize_children(&1, depth))
        _ -> %{"blocks" => []}
      end)
    end)
  end

  defp sanitize_children(blocks, depth) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn child ->
      case typed_attrs(child) do
        {nil, _attrs} ->
          []

        # A nested columns child recurses with the depth guard (bypassing the
        # sanitize_attrs columns clause, which would reset depth to 1).
        {"columns", _attrs} when depth >= @max_nesting ->
          []

        {"columns", attrs} ->
          [
            attrs
            |> Map.put("_type", "columns")
            |> sanitize_columns_block(depth + 1)
            |> drop_nils()
          ]

        {name, attrs} ->
          [attrs |> Map.put("_type", name) |> sanitize_attrs() |> drop_nils()]
      end
    end)
  end

  # Build a typed struct from a typed map (string or atom keys), upcasting first.
  defp struct_from_typed_map(map) do
    map = map |> stringify() |> KilnCMS.Blocks.Upcaster.upcast_block_map()

    case KilnCMS.Blocks.fetch(block_type_atom(map)) do
      {:ok, mod} ->
        struct(mod, typed_struct_kv(mod, map))

      :error ->
        # Carry the id so an unknown/plugin block keeps its identity across a
        # typed round-trip (known blocks already keep it via typed_struct_kv).
        %Custom{
          _type: "custom",
          id: get(map, :id),
          content: get(map, :content),
          data: get(map, :data) || %{}
        }
    end
  end

  @type_atoms Map.new(KilnCMS.Blocks.union_types(), fn {name, _opts} ->
                {to_string(name), name}
              end)
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

  # The oEmbed metadata (#489) rides in `data`, like every other block's
  # non-primary fields. Dropping it here loses the card on any legacy→typed
  # path, which is every delivery and preview read.
  defp typed(:embed, id, content, data, _block) do
    %Embed{
      id: id,
      _type: "embed",
      url: content,
      title: data_str(data, "title"),
      author_name: data_str(data, "author_name"),
      provider_name: data_str(data, "provider_name"),
      thumbnail_url: data_str(data, "thumbnail_url"),
      resolved_url: data_str(data, "resolved_url"),
      resolved_at: data_str(data, "resolved_at")
    }
  end

  defp typed(:divider, id, _content, _data, _block),
    do: %Divider{id: id, _type: "divider"}

  defp typed(:form, id, content, data, _block),
    do: %Form{id: id, _type: "form", form_slug: data_str(data, "form_slug") || content}

  # Repeating-item blocks: the item list rides in `data` as a raw string-keyed
  # map list, and the section heading rides in `content`.
  defp typed(:gallery, id, content, data, _block) do
    %Gallery{
      id: id,
      _type: "gallery",
      title: content,
      layout: data_str(data, "layout"),
      images: data_maps(data, "images")
    }
  end

  defp typed(:accordion, id, content, data, _block) do
    %Accordion{
      id: id,
      _type: "accordion",
      title: content,
      first_open: data_bool(data, "first_open"),
      panels: data_maps(data, "panels")
    }
  end

  # GEO blocks (#357): items/steps ride in `data` as raw string-keyed map lists.
  defp typed(:faq, id, content, data, _block),
    do: %Faq{id: id, _type: "faq", title: content, items: data_maps(data, "items")}

  defp typed(:how_to, id, content, data, _block) do
    %HowTo{
      id: id,
      _type: "how_to",
      name: content,
      description: data_str(data, "description"),
      steps: data_maps(data, "steps")
    }
  end

  defp typed(:claim, id, content, data, _block) do
    %Claim{
      id: id,
      _type: "claim",
      text: content,
      source_title: data_str(data, "source_title"),
      source_url: data_str(data, "source_url"),
      rating: data_str(data, "rating")
    }
  end

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

  # The single sanitize boundary for delivered/previewed rich text: stored
  # legacy_html is untrusted editor/API HTML and is scrubbed HERE, at
  # payload/preview build time (cached on delivery), while PT-rendered HTML is
  # trusted by construction (escaped text + allowlisted URLs + closed markup).
  # BlockComponents renders `content` raw — it must never receive rich-text
  # HTML that didn't come through this function.
  defp one_to_legacy(%RichText{} = b),
    do: %{
      type: :rich_text,
      content: rich_text_content(b),
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

  defp one_to_legacy(%Embed{} = b),
    do: %{
      type: :embed,
      content: b.url,
      data: %{
        "title" => b.title,
        "author_name" => b.author_name,
        "provider_name" => b.provider_name,
        "thumbnail_url" => b.thumbnail_url,
        "resolved_url" => b.resolved_url,
        "resolved_at" => b.resolved_at
      },
      id: b.id
    }

  defp one_to_legacy(%Divider{} = b), do: %{type: :divider, content: nil, data: %{}, id: b.id}

  defp one_to_legacy(%Form{} = b),
    do: %{type: :form, content: b.form_slug, data: %{"form_slug" => b.form_slug}, id: b.id}

  # Repeating-item blocks (#482): heading in `content`, item list in `data` as a
  # raw map list, normalized through the block module so delivery never has to
  # tell a missing key from a blank one.
  defp one_to_legacy(%Gallery{} = b),
    do: %{
      type: :gallery,
      content: b.title,
      data: %{"layout" => b.layout, "images" => Gallery.images(b)},
      id: b.id
    }

  defp one_to_legacy(%Accordion{} = b),
    do: %{
      type: :accordion,
      content: b.title,
      data: %{"first_open" => b.first_open == true, "panels" => Accordion.panels(b)},
      id: b.id
    }

  # GEO blocks (#357): the primary text rides in `content`, the rest in `data`
  # (items/steps stay raw map lists — see the block modules).
  defp one_to_legacy(%Faq{} = b),
    do: %{type: :faq, content: b.title, data: %{"items" => KilnCMS.Blocks.Faq.items(b)}, id: b.id}

  defp one_to_legacy(%HowTo{} = b),
    do: %{
      type: :how_to,
      content: b.name,
      data: %{"description" => b.description, "steps" => KilnCMS.Blocks.HowTo.steps(b)},
      id: b.id
    }

  defp one_to_legacy(%Claim{} = b),
    do: %{
      type: :claim,
      content: b.text,
      data: %{
        "source_title" => b.source_title,
        "source_url" => b.source_url,
        "rating" => b.rating
      },
      id: b.id
    }

  # The container's layout + child tree ride in `data` (`content`/`children` stay
  # empty). Delivery reads `data["columns"]` to render the nested tree — see
  # `KilnCMSWeb.BlockComponents`.
  defp one_to_legacy(%Columns{} = b),
    do: %{
      type: :columns,
      content: nil,
      data: %{"layout" => b.layout, "gap" => b.gap, "columns" => b.columns || []},
      id: b.id
    }

  defp one_to_legacy(%Custom{} = b),
    do: %{type: to_type(b.legacy_type), content: b.content, data: b.data || %{}, id: b.id}

  # Total fallback. Every preview surface (`preview_live`, `token_preview_live`,
  # `release_preview_live`, the in-context editor, the editor's own pop-out
  # preview) funnels through here, so a block type with no clause above is a
  # crash on those pages rather than a missing block — and the set without one
  # grows every time a block is added (`video`, `audio`, `file` and now
  # `fragment` all lacked one). A content-free legacy block renders as nothing,
  # which is what these surfaces should show for a block they can't project.
  defp one_to_legacy(%_{} = block),
    do: %{type: :custom, content: nil, data: %{}, id: Map.get(block, :id)}

  defp rich_text_content(%RichText{legacy_html: html}) when is_binary(html) and html != "",
    do: KilnCMS.HTMLSanitizer.sanitize_rich_text(html)

  defp rich_text_content(%RichText{body: body}), do: KilnCMS.Blocks.PortableText.to_html(body)

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

  # A jsonb list-of-maps value (faq items / how_to steps); anything else → [].
  defp data_maps(data, key) do
    case Map.get(data, key) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # A jsonb boolean. Strings are accepted because form params are always strings
  # and `one_to_legacy/1` writes a real boolean — the value has to survive a
  # round trip through both.
  defp data_bool(data, key) do
    case Map.get(data, key) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> value in ["true", "1", "on"]
      _ -> false
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
