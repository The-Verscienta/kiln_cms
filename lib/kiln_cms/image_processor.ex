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

  @type variant :: %{label: String.t(), path: Path.t(), width: pos_integer, height: pos_integer}

  # Canonical {extension, content_type} per allowed libvips loader. Deny-by-default:
  # anything else (svgload, tiffload, pdfload, …) is rejected.
  @allowed_formats %{
    "jpegload" => {".jpg", "image/jpeg"},
    "pngload" => {".png", "image/png"},
    "webpload" => {".webp", "image/webp"},
    "gifload" => {".gif", "image/gif"}
  }

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
         true <- Image.width(image) > 0 and Image.height(image) > 0,
         {:ok, loader} <- Vix.Vips.Image.header_value(image, "vips-loader"),
         {:ok, {ext, content_type}} <- allowed_format(loader) do
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

      other ->
        File.rm(tmp)
        {:error, other}
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
  e.g. `".png"`) to the temp dir. Returns the dimensions and variant temp files.
  """
  @spec process(Path.t(), String.t()) ::
          {:ok, %{width: pos_integer, height: pos_integer, variants: [variant]}}
          | {:error, term}
  def process(path, ext) do
    case Image.open(path) do
      {:ok, image} ->
        width = Image.width(image)
        height = Image.height(image)
        {:ok, %{width: width, height: height, variants: build_variants(image, width, ext)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor failed for #{path}: #{inspect(e)}")
      {:error, e}
  end

  defp build_variants(image, src_width, ext) do
    @targets
    |> Enum.filter(fn {_label, target} -> target < src_width end)
    |> Enum.map(fn {label, target} -> thumb(image, label, target, ext) end)
    |> Enum.reject(&is_nil/1)
  end

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
