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
  """
  use Phoenix.Component

  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.Media.{ImageTransform, Presentation}

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
end
