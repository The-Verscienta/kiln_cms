defmodule KilnCMS.Media.Presentation do
  @moduledoc """
  Turns a `KilnCMS.CMS.MediaItem` into the two presentation values delivery
  needs: a responsive `srcset` and an `object-position` from the focal point.

  Extracted from `KilnCMSWeb.ContentController` when the gallery block (#482)
  became the second consumer. It was a private function there, which was fine
  while `image` was the only block with media behind it — but `srcset/1`
  encodes a rule that is easy to get wrong and expensive to get wrong twice
  (see below), and the way that rule gets reintroduced is somebody writing a
  second builder rather than finding the first.

  ## Cropped variants are excluded from `srcset`, always

  `KilnCMS.ImageProcessor` produces two kinds of variant: plain downscales
  (`thumb`, `medium`) and focal-aware **crops** (`card`, 800×450). A `srcset` is
  a set of interchangeable renderings of *the same image* — the browser picks by
  width and expects the aspect ratio to be identical. A crop is a different
  picture. Putting `card` in the list means the browser silently swaps in a
  differently-shaped image at some viewport widths, which reads as a rendering
  bug nobody can reproduce on their own screen.

  So the exclusion comes from `ImageProcessor.cropped_labels/0` rather than a
  hardcoded list here: a future cropped variant is excluded the day it is added,
  without anyone remembering this rule.

  A video's poster frame (`AVProcessor.poster_label/0`, #494) shares the same
  `variants` map and is excluded for a stronger version of the same reason: it
  isn't an alternate rendering of the item at all, it's a still of something
  the item plays.

  ## One `srcset` per encoding, never one mixed

  Since #473 a variant exists in the source format *and* in every configured
  alternate (WebP by default), keyed `"thumb"` and `"thumb.webp"`. `srcset/1`
  still returns only the **source-format** set plus the original: that value is
  an `<img srcset>`, and a browser picking from it goes on width alone — mixing
  encodings there would hand a JPEG-only client a WebP at some viewport widths
  and, worse, offer two entries at the same width for it to choose between
  arbitrarily.

  Format negotiation is `<picture>`'s job instead: `sources/1` returns one
  `srcset` per alternate encoding, each tagged with its `type`, which is the
  only construct where the browser is told what it is choosing.

  A matching `<source>` **replaces** the `<img>`'s srcset rather than adding to
  it, which is why the alternates include a full-size `full.<format>` encoding:
  without it a WebP-capable browser would never see a candidate wider than the
  largest downscale, and every image would quietly render smaller than it used
  to.
  """

  alias KilnCMS.AVProcessor
  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.ImageProcessor

  # Most efficient first — `<picture>` picks the first supported `<source>`.
  @format_preference ["image/avif", "image/webp"]

  @doc """
  Every `variants` label that must stay out of a `srcset` — the focal-aware
  crops and the video poster frame. Exposed so the rule is assertable rather
  than only enforceable.
  """
  @spec excluded_labels() :: [String.t()]
  def excluded_labels, do: [AVProcessor.poster_label() | ImageProcessor.cropped_labels()]

  @doc """
  A responsive `srcset` for a media item — its non-cropped variants plus the
  original — or `nil` when nothing is renderable.

      "/uploads/thumb.jpg 400w, /uploads/medium.jpg 1024w, /uploads/orig.jpg 1600w"

  Every url goes through `HTMLSanitizer.safe_image_src/1`: variants are
  generated internally, but the original's url can come from an operator-set
  storage prefix, and one unfiltered entry poisons the whole attribute.
  """
  @spec srcset(map()) :: String.t() | nil
  def srcset(item) do
    original =
      case item.width && HTMLSanitizer.safe_image_src(item.url) do
        url when is_binary(url) -> [{url, item.width}]
        _ -> []
      end

    case renderable(item, fn label, _variant -> source_format?(label) end) ++ original do
      [] -> nil
      parts -> to_srcset(parts)
    end
  end

  @doc """
  `<picture>` sources for the item's **alternate** encodings (#473) — one entry
  per format, most efficient first:

      [%{type: "image/avif", srcset: "/uploads/thumb.avif 400w, …"}, …]

  Empty when the item has no alternates, which is what an upload processed
  before #473 (or one whose encoder was unavailable) looks like — the caller
  then renders a plain `<img>` and nothing is lost.

  Ordering is the whole contract of `<picture>`: a browser takes the **first**
  `<source>` whose `type` it supports, so the most efficient format has to come
  first. AVIF beats WebP beats the original.

  ## A format is only offered when its ladder reaches the full width (#919)

  A matching `<source>` **replaces** the `<img>`'s `srcset` outright — it does
  not supplement it. So a format whose alternates stop short of `item.width`
  does not merely miss the top rung; it removes the original from consideration
  for every browser that supports that format.

  `full.<format>` is what normally carries that top rung, and `write/4` drops a
  variant it cannot encode with only a log line. A 17000×2000 panorama whose
  `full.webp` exceeds libvips' WebP dimension limit therefore kept emitting
  `<source type="image/webp" srcset="…thumb 400w, …medium 1024w">`, and every
  WebP-capable browser upscaled a 1024px render of it — the exact regression
  `full` exists to prevent.

  So a format is offered only when its widest alternate reaches `item.width`.

  Be clear about what suppression costs, because it is more than "the smaller
  encoding": blocks render `sizes="(max-width: 768px) 100vw, 768px"`, so a 2x
  display wants ~1536px, and against the `<img>` ladder
  (`thumb 400w, medium 1024w, orig 17000w`) that selects the **original** — a
  full-resolution download where the buggy `<source>` served a 1024px WebP.
  It is still the right trade: it is exactly what every WebP-less browser
  already gets, and the alternative is a visibly upscaled image. But it is a
  bandwidth cost, not a codec-efficiency one.
  """
  @spec sources(map()) :: [%{type: String.t(), srcset: String.t()}]
  def sources(item) do
    for type <- @format_preference,
        parts =
          renderable(item, fn label, variant ->
            # Alternates only — a key with a format suffix. A WebP *upload*'s
            # variants are written once under the bare label and carry
            # `image/webp`, so matching on content type alone would emit a
            # `<source>` listing the very files the `<img>` fallback already
            # has, minus the original — strictly worse than no `<picture>`.
            not source_format?(label) and content_type(variant) == type
          end),
        parts != [],
        reaches_full_width?(item, parts),
        do: %{type: type, srcset: to_srcset(parts)}
  end

  # Whether this format's widest alternate is at least the item's intrinsic
  # width. `full.<format>` is written at source resolution, so its presence is
  # what normally satisfies this and its absence is what fails it.
  #
  # An item with no recorded width is not processed, so there is nothing to fall
  # short of — and the `<img>` fallback has no original entry either, which
  # makes the `<source>` no worse than what it replaces.
  defp reaches_full_width?(%{width: width}, parts) when is_integer(width) do
    Enum.any?(parts, fn {_url, w} -> is_integer(w) and w >= width end)
  end

  defp reaches_full_width?(_item, _parts), do: true

  defp to_srcset(parts), do: Enum.map_join(parts, ", ", fn {url, w} -> "#{url} #{w}w" end)

  # `"<url> <width>w"` for every variant that passes `keep?`, excluding crops
  # and poster frames by their BASE label: `card.webp` is still the card crop,
  # and comparing the raw key would let an alternate encoding of an excluded
  # variant back into a srcset.
  #
  # Every url goes through `safe_image_src/1`: variants are generated
  # internally, but the original's url can come from an operator-set storage
  # prefix, and one unfiltered entry poisons the whole attribute.
  # Returns `{url, width}` pairs rather than formatted strings: `sources/1` has
  # to compare the widths against `item.width` before it decides whether to emit
  # the format at all, and re-parsing them out of a joined srcset would be a
  # second place for the shape to drift.
  defp renderable(item, keep?) do
    excluded = excluded_labels()

    for {label, %{"url" => url, "width" => w} = variant} <- item.variants || %{},
        ImageProcessor.base_label(label) not in excluded,
        keep?.(label, variant),
        safe = HTMLSanitizer.safe_image_src(url),
        is_binary(safe),
        do: {safe, w}
  end

  # A variant is in the source format when its key carries no format suffix —
  # that is exactly how `ImageProcessor` writes the `<img>` fallback.
  defp source_format?(label), do: label == ImageProcessor.base_label(label)

  defp content_type(%{"content_type" => type}) when is_binary(type), do: type
  defp content_type(_variant), do: nil

  @doc """
  An `object-position` declaration from the item's focal point, so a theme
  cropping via `object-fit` keeps the subject in frame.

  `nil` at the default centre — no styling noise on untouched media.
  """
  @spec focal_style(map()) :: String.t() | nil
  def focal_style(%{focal_x: x, focal_y: y})
      when is_number(x) and is_number(y) and (x != 0.5 or y != 0.5) do
    "object-position: #{round(x * 100)}% #{round(y * 100)}%"
  end

  def focal_style(_item), do: nil
end
