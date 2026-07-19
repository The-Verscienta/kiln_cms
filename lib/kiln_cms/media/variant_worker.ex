defmodule KilnCMS.Media.VariantWorker do
  @moduledoc """
  Generates responsive image variants for a freshly-uploaded `MediaItem` in the
  background, off the upload request path.

  `MediaLive` stores the original and creates the `MediaItem`, then enqueues this
  worker with just the item id. Here we **re-fetch the original from storage**
  (`KilnCMS.Storage.fetch/1`) into a temp file, run `KilnCMS.ImageProcessor`
  over it, persist the downscaled variants, and write the intrinsic dimensions +
  variant map back onto the `MediaItem`. Re-fetching (rather than a node-local
  temp hand-off) means the job runs correctly on any node.

  When processing finishes it broadcasts on `"media:updated"` so an open media
  library refreshes live. A non-raster upload (or a since-deleted item / missing
  original) is a graceful no-op — the original is still served.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias KilnCMS.{CMS, ImageProcessor, Storage}

  @topic "media:updated"

  @doc "PubSub topic broadcast when an item's variants finish processing."
  def topic, do: @topic

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => id} = args}) do
    # `org_id` scopes the re-fetch/update to the item's site (epic #336). Old jobs
    # enqueued before #336 carry no `org_id`; a nil tenant reads globally, which
    # under `global?: true` still finds the row by its (globally-unique) id.
    tenant = args["org_id"]

    case CMS.get_media_item(id, authorize?: false, tenant: tenant) do
      {:ok, %{storage_key: key} = item} when is_binary(key) -> process(item, key, tenant)
      _ -> :ok
    end
  end

  defp process(item, key, tenant) do
    case Storage.fetch(key) do
      {:ok, binary} ->
        tmp = write_temp(binary, Path.extname(key))

        try do
          generate(item, tmp, Path.extname(key), tenant)
        after
          rm(tmp)
        end

        broadcast(item.id)
        :ok

      # Original isn't readable (e.g. removed) — nothing to do; keep the original.
      {:error, _} ->
        :ok
    end
  end

  defp generate(item, path, ext, tenant) do
    focal = %{x: item.focal_x || 0.5, y: item.focal_y || 0.5}

    case ImageProcessor.process(path, ext, focal) do
      {:ok, %{width: width, height: height, variants: files}} ->
        {:ok, _item} =
          CMS.update_media_item(
            item,
            %{width: width, height: height, variants: store_variants(files, ext)},
            authorize?: false,
            tenant: tenant
          )

      {:error, _} ->
        # Not a processable raster image — keep the original only.
        :ok
    end
  end

  # `tmp` paths are server-built (System.tmp_dir! + a UUID), never user input —
  # so the File traversal warnings are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp(binary, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-variant-#{Ecto.UUID.generate()}#{ext}")
    File.write!(tmp, binary)
    tmp
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp store_variants(files, ext) do
    Map.new(files, fn %{label: label, path: tmp, width: w, height: h} ->
      key = Storage.generate_key("#{label}#{ext}")
      {:ok, ^key} = Storage.store(key, tmp)
      rm(tmp)
      {label, %{"key" => key, "url" => Storage.url(key), "width" => w, "height" => h}}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)

  defp broadcast(id) do
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:media_processed, id})
  end
end
