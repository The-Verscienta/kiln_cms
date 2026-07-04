defmodule KilnCMS.ImageProcessor do
  @moduledoc """
  Reads intrinsic dimensions and generates downscaled responsive variants from
  an uploaded image, via libvips (Vix/Image).

  Degrades gracefully: anything that isn't a readable raster image returns
  `{:error, _}`, and callers fall back to storing the original only (no
  dimensions, no variants). Variants are written to temp files; the caller is
  responsible for persisting and cleaning them up.
  """

  require Logger

  # Responsive target widths. A variant is only produced when the source is
  # wider than the target (we never upscale).
  @targets [thumb: 400, medium: 1024]

  # Focal-aware cropped variants: `{label, {width, height}}`. The crop window
  # takes the target's aspect ratio, centers on the focal point (clamped to
  # the source bounds), then downscales — never upscales. Skipped when the
  # source is smaller than the target box.
  @cropped [card: {800, 450}]

  @type variant :: %{label: String.t(), path: Path.t(), width: pos_integer, height: pos_integer}
  @type focal :: %{x: float(), y: float()}

  @doc """
  Labels of the focal-aware **cropped** variants. Cropped variants change the
  aspect ratio, so responsive `srcset` builders must exclude them — a browser
  picking the crop for a plain `<img>` would show the wrong framing.
  """
  @spec cropped_labels() :: [String.t()]
  def cropped_labels, do: Enum.map(@cropped, fn {label, _dims} -> to_string(label) end)

  # Canonical {extension, content_type} per allowed libvips loader. Deny-by-default:
  # anything else (svgload, tiffload, pdfload, …) is rejected.
  @allowed_formats %{
    "jpegload" => {".jpg", "image/jpeg"},
    "pngload" => {".png", "image/png"},
    "webpload" => {".webp", "image/webp"},
    "gifload" => {".gif", "image/gif"}
  }

  # Decompression-bomb guard: a small compressed file can expand to a huge
  # pixel buffer (a 10MB PNG can decode to multiple GB). Opening is lazy in
  # libvips — dimensions come from the header — so this cap is checked before
  # any full decode (metadata strip, variants) can happen. 50MP comfortably
  # covers real photography. Runtime-configurable for tests/deployments.
  @default_max_pixels 50_000_000

  defp max_pixels do
    :kiln_cms |> Application.get_env(:media, []) |> Keyword.get(:max_pixels, @default_max_pixels)
  end

  @doc """
  Returns `{:ok, %{ext: ".png", content_type: "image/png"}}` when `path` is a
  readable raster image in an allowed format, deriving the canonical extension and
  content-type from the actual bytes (not the client-supplied name/MIME). Rejects
  anything else with `{:error, _}`.
  """
  @spec validate_upload(Path.t()) ::
          {:ok, %{ext: String.t(), content_type: String.t()}} | {:error, term}
  def validate_upload(path) when is_binary(path) do
    with {:ok, image} <- Image.open(path),
         {:ok, loader} <- Vix.Vips.Image.header_value(image, "vips-loader"),
         {:ok, {ext, content_type}} <- allowed_format(loader),
         :ok <- within_pixel_limit(image) do
      {:ok, %{ext: ext, content_type: content_type}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_image}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.validate_upload failed for #{path}: #{inspect(e)}")
      {:error, :invalid_image}
  end

  # Total pixels across all frames (animated GIF/WebP multiply the buffer).
  defp within_pixel_limit(image) do
    frames =
      case Vix.Vips.Image.header_value(image, "n-pages") do
        {:ok, n} when is_integer(n) and n > 0 -> n
        _ -> 1
      end

    if Image.width(image) * Image.height(image) * frames <= max_pixels(),
      do: :ok,
      else: {:error, :too_many_pixels}
  end

  defp allowed_format(loader) when is_binary(loader) do
    case Map.fetch(@allowed_formats, String.replace_suffix(loader, "_buffer", "")) do
      {:ok, fmt} -> {:ok, fmt}
      :error -> {:error, :unsupported_format}
    end
  end

  defp allowed_format(_), do: {:error, :unsupported_format}

  @doc """
  Re-encodes `path` (already validated, with canonical `ext`) to a temp file
  with **all metadata stripped** — EXIF/GPS, camera info, and the original
  client filename. Returns `{:ok, stripped_tmp_path}`; the caller owns the temp
  file. On any failure returns `{:error, reason}` so the caller can fall back to
  storing the original. Multi-page/animated sources (GIF/WebP) are opened with
  all frames so animation is preserved.

  Privacy (#215): uploaded photos commonly carry GPS and device metadata. Both
  the stored original and (via re-fetch in `Media.VariantWorker`) its variants
  are sourced from this stripped copy.
  """
  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  @spec strip_metadata(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term}
  def strip_metadata(path, ext) when is_binary(path) and is_binary(ext) do
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-stripped#{ext}")

    with {:ok, image} <- open_all_pages(path),
         {:ok, stripped} <- strip(image),
         {:ok, _} <- Image.write(stripped, tmp) do
      {:ok, tmp}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.strip_metadata failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  # Drop every header field (all EXIF incl. GPS/device/filename, plus XMP/IPTC)
  # so libvips can't regenerate the EXIF blob from leftover `exif-ifd*` fields on
  # save. We remove fields directly rather than via the `strip` save flag (a
  # silent no-op on current libvips) or `minimize_metadata` (which first *reads*
  # EXIF and errors out on a thumbnail's regenerated `:invalid_exif` blob).
  defp strip(image), do: Image.remove_metadata(image, [])

  # Prefer loading every frame (animated GIF/WebP) so stripping doesn't flatten
  # animation; single-page loaders (JPEG/PNG) reject `pages:` so fall back.
  defp open_all_pages(path) do
    case Image.open(path, pages: :all) do
      {:ok, image} -> {:ok, image}
      _ -> Image.open(path)
    end
  end

  @doc """
  Analyzes `path` and writes any applicable variants (with extension `ext`,
  e.g. `".png"`) to the temp dir: the downscaled responsive set plus the
  focal-aware crops (see `@cropped`), cropped around `focal` (fractions of
  the source dimensions, default center). Returns the dimensions and variant
  temp files.
  """
  @spec process(Path.t(), String.t(), focal()) ::
          {:ok, %{width: pos_integer, height: pos_integer, variants: [variant]}}
          | {:error, term}
  def process(path, ext, focal \\ %{x: 0.5, y: 0.5}) do
    case Image.open(path) do
      {:ok, image} ->
        width = Image.width(image)
        height = Image.height(image)

        variants =
          build_variants(image, width, ext) ++ build_crops(image, width, height, focal, ext)

        {:ok, %{width: width, height: height, variants: variants}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Applies a geometric edit to the (validated) image at `path`, writing the
  result to a temp file with extension `ext`. Returns the temp path and the
  resulting dimensions; the caller owns the temp file. Metadata is stripped
  on the way out, like every other write in this module.
  """
  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File.rm traversal warning is a false positive (same as strip_metadata/2).
  # sobelow_skip ["Traversal.FileModule"]
  @spec transform(
          Path.t(),
          String.t(),
          :rotate_left | :rotate_right | :flip_horizontal | :flip_vertical
        ) ::
          {:ok, %{path: Path.t(), width: pos_integer, height: pos_integer}} | {:error, term}
  def transform(path, ext, op)
      when op in [:rotate_left, :rotate_right, :flip_horizontal, :flip_vertical] do
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-edit#{ext}")

    with {:ok, image} <- Image.open(path),
         {:ok, edited} <- apply_op(image, op),
         {:ok, edited} <- strip(edited),
         {:ok, _} <- Image.write(edited, tmp) do
      {:ok, %{path: tmp, width: Image.width(edited), height: Image.height(edited)}}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.transform failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  defp apply_op(image, :rotate_left), do: Image.rotate(image, -90.0)
  defp apply_op(image, :rotate_right), do: Image.rotate(image, 90.0)
  defp apply_op(image, :flip_horizontal), do: Image.flip(image, :horizontal)
  defp apply_op(image, :flip_vertical), do: Image.flip(image, :vertical)

  defp build_variants(image, src_width, ext) do
    @targets
    |> Enum.filter(fn {_label, target} -> target < src_width end)
    |> Enum.map(fn {label, target} -> thumb(image, label, target, ext) end)
    |> Enum.reject(&is_nil/1)
  end

  # Focal-aware crops: a window with the target's aspect ratio, as large as the
  # source allows, centered on the focal point and clamped to the bounds — the
  # subject stays in frame wherever it sits.
  defp build_crops(image, w, h, focal, ext) do
    @cropped
    |> Enum.filter(fn {_label, {tw, th}} -> w >= tw and h >= th end)
    |> Enum.map(fn {label, {tw, th}} -> focal_crop(image, w, h, focal, label, {tw, th}, ext) end)
    |> Enum.reject(&is_nil/1)
  end

  defp focal_crop(image, w, h, focal, label, {tw, th}, ext) do
    aspect = tw / th

    {crop_w, crop_h} =
      if w / h > aspect,
        do: {round(h * aspect), h},
        else: {w, round(w / aspect)}

    left = clamp(round(focal.x * w - crop_w / 2), 0, w - crop_w)
    top = clamp(round(focal.y * h - crop_h / 2), 0, h - crop_h)

    with {:ok, cropped} <- Image.crop(image, left, top, crop_w, crop_h),
         {:ok, resized} <- Image.thumbnail(cropped, tw),
         {:ok, resized} <- strip(resized),
         tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-#{label}#{ext}"),
         {:ok, _} <- Image.write(resized, tmp) do
      %{
        label: to_string(label),
        path: tmp,
        width: Image.width(resized),
        height: Image.height(resized)
      }
    else
      _ -> nil
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp thumb(image, label, target, ext) do
    with {:ok, resized} <- Image.thumbnail(image, target),
         # Defense-in-depth: strip metadata on variants too, so they never carry
         # EXIF/GPS even if a future caller processes an un-stripped original (#215).
         {:ok, resized} <- strip(resized),
         tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-#{label}#{ext}"),
         {:ok, _} <- Image.write(resized, tmp) do
      %{
        label: to_string(label),
        path: tmp,
        width: Image.width(resized),
        height: Image.height(resized)
      }
    else
      _ -> nil
    end
  end
end
