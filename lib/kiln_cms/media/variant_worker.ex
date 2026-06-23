defmodule KilnCMS.Media.VariantWorker do
  @moduledoc """
  Generates responsive image variants for a freshly-uploaded `MediaItem` in the
  background, off the upload request path.

  `MediaLive` stores the original, creates the `MediaItem`, copies the upload to
  a temp file and enqueues this worker. Here we run `KilnCMS.ImageProcessor`
  over that temp file, persist the downscaled variants to storage, and write the
  intrinsic dimensions + variant map back onto the `MediaItem`.

  A non-raster upload (or a `MediaItem` that has since been deleted) is a
  graceful no-op — the original is still served. The temp file is removed once
  processing finishes; if processing fails it is left in place so Oban can retry.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias KilnCMS.{CMS, ImageProcessor, Storage}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => id, "source_path" => path, "ext" => ext}}) do
    case CMS.get_media_item(id, authorize?: false) do
      {:ok, item} -> generate(item, path, ext)
      _ -> :ok
    end

    cleanup(path)
    :ok
  end

  defp generate(item, path, ext) do
    case ImageProcessor.process(path, ext) do
      {:ok, %{width: width, height: height, variants: files}} ->
        {:ok, _item} =
          CMS.update_media_item(
            item,
            %{width: width, height: height, variants: store_variants(files, ext)},
            authorize?: false
          )

      {:error, _} ->
        # Not a processable raster image — keep the original only.
        :ok
    end
  end

  # `tmp` is an ImageProcessor-built path (System.tmp_dir! + a UUID), never user
  # input — so the File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp store_variants(files, ext) do
    Map.new(files, fn %{label: label, path: tmp, width: w, height: h} ->
      key = Storage.generate_key("#{label}#{ext}")
      {:ok, ^key} = Storage.store(key, tmp)
      File.rm(tmp)
      {label, %{"key" => key, "url" => Storage.url(key), "width" => w, "height" => h}}
    end)
  end

  # The source path is created by MediaLive (System.tmp_dir! + a UUID), not user
  # input — so the File.rm traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup(path), do: File.rm(path)
end
