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

  # Upload allowlist, keyed by the libvips loader that actually parsed the
  # bytes. Detection is content-based (the loader libvips chose), NOT the
  # filename or client-supplied MIME — so a PNG renamed `evil.svg` is detected
  # as PNG, and an SVG/TIFF/PDF/HEIC is rejected even when libvips can open it.
  # The mapped extension + Content-Type are what callers persist.
  @allowed_loaders %{
    "jpegload" => {".jpg", "image/jpeg"},
    "pngload" => {".png", "image/png"},
    "webpload" => {".webp", "image/webp"},
    "gifload" => {".gif", "image/gif"}
  }

  @type variant :: %{label: String.t(), path: Path.t(), width: pos_integer, height: pos_integer}
  @type format :: %{extension: String.t(), content_type: String.t()}

  @doc """
  Validates an upload by its content and returns the detected format.

  Returns `{:ok, %{extension: ".png", content_type: "image/png"}}` when `path`
  is a readable raster image with non-zero dimensions whose libvips-detected
  format is in the allowlist (#{inspect(Map.keys(@allowed_loaders))}), and
  `{:error, _}` otherwise.

  Callers MUST derive the stored extension and persisted `content_type` from the
  returned format — never from the upload's filename or client MIME type — so a
  file whose bytes don't match its name can't be stored as active content.
  """
  @spec validate_upload(Path.t()) :: {:ok, format} | {:error, term}
  def validate_upload(path) when is_binary(path) do
    with {:ok, image} <- Image.open(path),
         true <- Image.width(image) > 0 and Image.height(image) > 0,
         {:ok, loader} <- Vix.Vips.Image.header_value(image, "vips-loader"),
         {:ok, {ext, content_type}} <- Map.fetch(@allowed_loaders, loader) do
      {:ok, %{extension: ext, content_type: content_type}}
    else
      false -> {:error, :invalid_image}
      :error -> {:error, :unsupported_format}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ImageProcessor.validate_upload failed for #{path}: #{inspect(e)}")
      {:error, :invalid_image}
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
