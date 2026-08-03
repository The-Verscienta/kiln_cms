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
  """

  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.ImageProcessor

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
    cropped = ImageProcessor.cropped_labels()

    variant_parts =
      for {label, %{"url" => url, "width" => w}} <- item.variants || %{},
          label not in cropped,
          safe = HTMLSanitizer.safe_image_src(url),
          is_binary(safe),
          do: "#{safe} #{w}w"

    original =
      case item.width && HTMLSanitizer.safe_image_src(item.url) do
        url when is_binary(url) -> ["#{url} #{item.width}w"]
        _ -> []
      end

    case variant_parts ++ original do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

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
