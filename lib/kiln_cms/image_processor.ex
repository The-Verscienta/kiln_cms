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
