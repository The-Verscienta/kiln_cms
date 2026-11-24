defmodule KilnCMSWeb.MediaComponents do
  @moduledoc """
  Responsive images from on-the-fly transforms (`KilnCMS.Media.ImageTransform`),
  for public templates and overlays.

      <KilnCMSWeb.MediaComponents.transform_img
        item={@post.featured_image}
        sizes="(max-width: 768px) 100vw, 768px"
        aspect_ratio="16:9"
        alt={@post.title}
      />

  One `<img>` rather than a `<picture>`: the URLs ask for `fm_auto`, so the
  server picks AVIF/WebP/the source format from the browser's `Accept` header
  and every candidate is already the best encoding that browser takes. The
  URLs are signed with this deployment's key, so any width works — the
  allowlist only binds unsigned URLs built elsewhere — and version-pinned, so
  a CDN may keep them for a year.

  The block renderer (`KilnCMSWeb.BlockComponents`) still uses the fixed
  variants generated at upload; this is for templates that want a size or a
  crop those don't have.

  `thumb_src/2` is the one rule for which small preview an item has, shared
  by the media library's grid and the reference picker's rows.
  """
  use Phoenix.Component

  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.ImageProcessor
  alias KilnCMS.Media.{ImageTransform, Presentation}
  alias KilnCMS.MediaKind

  attr :item, :map, required: true, doc: "a `MediaItem` (id, url, width, height, focal point)"
  attr :sizes, :string, default: "100vw"
  attr :widths, :list, default: nil, doc: "candidate widths; default: the allowlist from 256 up"

  attr :aspect_ratio, :string,
    default: nil,
    doc: ~s(crop every candidate to this ratio, e.g. "16:9", around the focal point)

  attr :format, :atom, default: :auto, values: [:auto, :jpg, :png, :webp, :avif]
  attr :quality, :integer, default: nil
  attr :alt, :string, default: nil, doc: "defaults to the item's own alt text"

  attr :rest, :global,
    include: ~w(loading decoding fetchpriority class),
    default: %{loading: "lazy", decoding: "async"}

  def transform_img(assigns) do
    item = assigns.item
    opts = transform_opts(assigns)
    srcset = ImageTransform.srcset(item, assigns.widths, opts)

    assigns =
      assigns
      |> assign(:srcset, srcset)
      |> assign(:src, fallback_src(item, srcset, assigns.widths, opts))
      |> assign(:dimensions, dimensions(item, assigns.aspect_ratio))
      |> assign(:alt_text, assigns.alt || Map.get(item, :alt) || "")
      |> assign(:rest, with_focal(assigns.rest, item, assigns.aspect_ratio))

    ~H"""
    <img
      :if={@src}
      src={@src}
      srcset={@srcset}
      sizes={@srcset && @sizes}
      width={elem(@dimensions, 0)}
      height={elem(@dimensions, 1)}
      alt={@alt_text}
      {@rest}
    />
    """
  end

  defp transform_opts(assigns) do
    [aspect_ratio: assigns.aspect_ratio, format: assigns.format, quality: assigns.quality]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The `src` a browser without `srcset` support (or a crawler) takes: a
  # mid-sized rendering when the item can be transformed, else the stored url
  # — a document or an unprocessed upload still shows whatever it has.
  defp fallback_src(item, nil, _widths, _opts),
    do: HTMLSanitizer.safe_image_src(Map.get(item, :url))

  defp fallback_src(item, _srcset, widths, opts) do
    widest = if widths, do: Enum.max(widths), else: item.width
    ImageTransform.url(item, Keyword.put(opts, :width, Enum.min([1080, widest, item.width])))
  end

  # An uncropped image keeps its subject in frame under a theme's
  # `object-fit` via the focal point; a crop already framed it. Folded into
  # the global attributes (rather than `style={…}`, which renders an empty
  # `style=""` for nil) so a caller's own `style` wins.
  defp with_focal(rest, item, nil) do
    case Presentation.focal_style(item) do
      nil -> rest
      focal -> Map.put_new(rest, :style, focal)
    end
  end

  defp with_focal(rest, _item, _ratio), do: rest

  # Intrinsic size for layout (no shift while the image loads): the item's own,
  # or for a crop the largest window of that ratio, which is what the widest
  # candidate renders.
  defp dimensions(%{width: w, height: h}, nil) when is_integer(w) and is_integer(h), do: {w, h}

  defp dimensions(%{width: w, height: h}, ratio) when is_integer(w) and is_integer(h) do
    [a, b] = ratio |> String.split(":") |> Enum.map(&String.to_integer/1)
    width = min(w, max(1, round(h * a / b)))
    {width, max(1, round(width * b / a))}
  end

  defp dimensions(_item, _ratio), do: {nil, nil}

  @doc """
  The small preview image of a media item — the generated `"thumb"` variant
  when it has one — or `nil` when there is nothing to preview: a document
  (no `width`, so nothing was ever generated), a gated item (no public `url`,
  #481), or a video without a poster frame. A caller shows a badge or nothing
  in its place, never a broken `<img>`.

  An image without a `"thumb"` variant falls back to the original when it
  has a `width`, for the media library's grid. Pass `fallback: false` where a
  full-size download for a small slot is not worth it (the reference picker,
  #3223): such an image then falls back only when it is no wider than the
  `"thumb"` variant would be (`KilnCMS.ImageProcessor.thumb_width/0`), the
  case where the pipeline writes no variant because the original is already
  that small; a wider one has no preview.

  Dispatching on kind first matters for A/V (#494): a video ffprobe measured
  has a `width` exactly like an image does, so the image rules would otherwise
  put an `.mp4` in an `<img src>`. Its generated poster frame, when it has
  one, is the only image a video has.
  """
  @spec thumb_src(map(), keyword()) :: String.t() | nil
  def thumb_src(item, opts \\ []) do
    case MediaKind.of(item.content_type) do
      :image -> image_thumb_url(item, Keyword.get(opts, :fallback, true))
      :video -> poster_url(item)
      _kind -> nil
    end
  end

  @doc "A video's generated poster frame, or `nil` when it has none."
  @spec poster_url(map()) :: String.t() | nil
  def poster_url(%{variants: %{"poster" => %{"url" => url}}}), do: url
  def poster_url(_item), do: nil

  defp image_thumb_url(%{variants: %{"thumb" => %{"url" => url}}}, _fallback?), do: url

  defp image_thumb_url(%{width: width, url: url}, false) when is_integer(width),
    do: if(width <= ImageProcessor.thumb_width(), do: url)

  defp image_thumb_url(_item, false), do: nil
  defp image_thumb_url(%{width: nil}, true), do: nil
  defp image_thumb_url(item, true), do: item.url
end
