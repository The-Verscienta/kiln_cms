defmodule KilnCMS.Blocks.Gallery do
  @moduledoc """
  An ordered set of images with per-image alt text and captions (#482).

  The `image` block holds one image, and nothing held a list. A `columns` block
  can fake a grid, but it carries no gallery *semantics*: no shared layout, no
  per-item caption convention, and — because `columns` children are typed lazily
  — no single place for delivery to batch-load the media behind them. So an
  editor building a gallery got inconsistent crops, hand-placed captions, and a
  `@graph` that described several unrelated images rather than one collection.

  Shape (string keys, as stored):

      %{
        "_type" => "gallery",
        "title" => "Site photographs",
        "layout" => "grid",                  # see @layouts
        "images" => [
          %{"media_id" => "…", "url" => "…", "alt" => "…", "caption" => "…"}
        ]
      }

  Items are raw string-keyed maps (jsonb), mirroring `faq`'s items and `columns`'
  children: a map array keeps the storage union flat and the editor round-trip
  trivial. `media_id` is the real reference — `url` is denormalized alongside it
  so a fired artifact renders without a database read, exactly as the `image`
  block does.

  ## Alt text is per image, and blank is a claim

  Every item carries its own `alt`. An empty one is not "not filled in yet" —
  it is the ARIA convention for *decorative*, which is a claim about the image.
  `KilnCMS.CMS.Validations.MediaAltText` gates publishing on it per item, the
  same as it does for a lone `image` block, so a fifty-image gallery cannot
  smuggle fifty unlabelled images past a check that only ever looked at
  top-level `alt` fields.

  ## Layout is a hint, resolved through an allowlist

  `layout` names an intent (`@layouts`), never a CSS string. The rendered
  geometry is resolved from it here, so the fired `:web` artifact and the live
  delivery renderer (`KilnCMSWeb.BlockComponents`) lay a gallery out the same
  way and no user string reaches a `style` attribute. Same reasoning as
  `KilnCMS.Blocks.Columns.grid_style/3`, and for the same reason: this is the
  one field an editor types freely.
  """
  use Kiln.Block

  block :gallery do
    # Optional heading rendered above the grid.
    field :title, :string
    # Each entry: `%{"media_id", "url", "alt", "caption"}` (string keys, stored).
    field :images, {:array, :map}, default: []
    # Presentation intent — see @layouts. nil renders the default grid.
    field :layout, :string
  end

  # Layout intent → container style. An unknown or nil value falls back to
  # `grid`, so a hand-edited document or a layout removed in a later version
  # degrades to something that renders rather than to no style at all.
  #
  # `masonry` is CSS columns rather than grid: a true masonry needs measured
  # heights, and `column-count` gets the ragged-bottom look with no JS and no
  # layout shift. `carousel` is a scroll-snap row — horizontal scrolling is a
  # native affordance, so it also needs no JS and keeps working without it.
  @layouts %{
    "grid" => "display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem",
    "masonry" => "column-count:3;column-gap:1rem",
    "carousel" =>
      "display:grid;grid-auto-flow:column;grid-auto-columns:minmax(260px,1fr);" <>
        "gap:1rem;overflow-x:auto;scroll-snap-type:x mandatory"
  }
  @default_layout "grid"

  @doc "The known layout keys, for the editor's select."
  @spec layouts() :: [String.t()]
  def layouts, do: Map.keys(@layouts) |> Enum.sort()

  @doc """
  The container's inline `style` for a layout key — the single source of gallery
  geometry, shared by this block's `:web` serializer and the live delivery
  renderer so both lay a gallery out identically. Resolved through an allowlist,
  so no raw user string reaches the style (no CSS injection).
  """
  @spec layout_style(String.t() | nil) :: String.t()
  def layout_style(layout), do: Map.get(@layouts, layout, @layouts[@default_layout])

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    figures =
      for image <- images(block), image["url"] != "" do
        # Same guard the `image` block applies: reject non-http(s)/relative
        # schemes so fired `:web` HTML is safe for headless innerHTML consumers.
        src = KilnCMS.HTMLSanitizer.safe_image_src(image["url"]) || ""

        caption =
          case image["caption"] do
            "" -> []
            caption -> ["<figcaption>", esc(caption), "</figcaption>"]
          end

        [
          "<figure class=\"kiln-gallery-item\"><img src=\"",
          esc(src),
          "\" alt=\"",
          esc(image["alt"]),
          "\" loading=\"lazy\"/>",
          caption,
          "</figure>"
        ]
      end

    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["<h2>", esc(title), "</h2>"]
      end

    [
      "<section class=\"kiln-gallery\">",
      title,
      "<div class=\"kiln-gallery-items\" style=\"",
      esc(layout_style(block.layout)),
      "\">",
      figures,
      "</div></section>"
    ]
  end

  def render(block, :json),
    do: %{
      "_type" => "gallery",
      "title" => block.title,
      "layout" => block.layout || @default_layout,
      "images" => images(block)
    }

  # One `ImageGallery` node per block — the collection, not N loose images, which
  # is the whole structured-data reason this block exists rather than a row of
  # `image` blocks. Nothing for an empty gallery, mirroring `faq`.
  def render(block, :json_ld) do
    case Enum.filter(images(block), &(&1["url"] != "")) do
      [] ->
        nil

      images ->
        %{
          "@type" => "ImageGallery",
          "image" =>
            Enum.map(images, fn image ->
              %{"@type" => "ImageObject", "url" => image["url"]}
              |> put_if("caption", image["caption"])
              |> put_if("name", image["alt"])
            end)
        }
        |> put_if("name", block.title)
    end
  end

  # `images/1` normalizes every entry, so the delivered array is never null and
  # every item carries all four keys as strings — which "array of object" (all
  # a `{:array, :map}` field can be derived to) does not say. `layout` falls
  # back to the default, so it is never null either.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "properties" => %{
        "images" => Kiln.Block.JsonSchema.object_array(~w(media_id url alt caption)),
        # `layout` is NOT an enum. The `:json` render emits
        # `block.layout || @default_layout` with no allowlist pass — only the
        # `:web` render resolves it through `@layouts` — and nothing validates
        # the field on write, so an authored "polaroid" (or a form's "", which
        # is truthy, so the `||` never fires) is served verbatim.
        "layout" => %{"type" => ["string", "null"], "default" => @default_layout}
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    text =
      block
      |> images()
      |> Enum.map_join(" ", fn image -> String.trim("#{image["alt"]} #{image["caption"]}") end)

    String.trim("#{block.title || ""} #{text}")
  end

  # The `:llm` surface. Markdown images carry the alt text, which is the only
  # part of a gallery an answer engine can actually read.
  def to_markdown(block) do
    title =
      case block.title do
        nil -> []
        "" -> []
        title -> ["## " <> title]
      end

    entries =
      for image <- images(block), image["url"] != "" do
        caption = if image["caption"] == "", do: "", else: "\n\n#{image["caption"]}"
        "![#{image["alt"]}](#{image["url"]})#{caption}"
      end

    Enum.join(title ++ entries, "\n\n")
  end

  @doc """
  Normalized items: string-keyed maps with `media_id`/`url`/`alt`/`caption`.

  Every key is present and every value is a string, so callers — the serializers
  here, the delivery enrichment, the alt-text validation, the reference
  extractor — never have to distinguish a missing key from a blank one.
  """
  @spec images(struct()) :: [%{String.t() => String.t()}]
  def images(block) do
    block.images
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn image ->
      %{
        "media_id" => field_str(image, "media_id", :media_id),
        "url" => field_str(image, "url", :url),
        "alt" => field_str(image, "alt", :alt),
        "caption" => field_str(image, "caption", :caption)
      }
    end)
  end

  @doc """
  The `MediaItem` ids a gallery references, in order and without blanks.

  Used by the reference extractor (`KilnCMS.Firing.References`), which holds a
  typed struct. Delivery's batch media load wants the same list but reaches it
  from the *legacy* `data` map rather than a struct, so `KilnCMSWeb.ContentController`
  walks `data["images"]` itself. Two traversals of one shape is not ideal; both
  are one-liners over the same key, and the day delivery reads typed blocks it
  should call this instead.
  """
  @spec media_ids(struct()) :: [String.t()]
  def media_ids(block) do
    for %{"media_id" => id} <- images(block), id != "", do: id
  end

  # Tolerates string keys (jsonb/form params) and atom keys (seeds/tests).
  defp field_str(image, key, atom_key) do
    case Map.get(image, key) || Map.get(image, atom_key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
