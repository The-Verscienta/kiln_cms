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

  Re-running the worker for an item that already has variants is safe and is how
  bulk regeneration works (#473): each run writes a fresh set under fresh
  storage keys, replaces the map wholesale, and then **deletes the blobs the old
  map named**. Reclaiming them matters because regeneration is a documented,
  encouraged operation — a single run over a ten-thousand-image library would
  otherwise orphan tens of thousands of unreferenced files that no purge, trash
  or task could ever find. Deleting only after the update commits means a failed
  write leaves the old variants intact and still referenced.

  Safe because no published document points at a variant key: delivery computes
  `srcset` live from the current map, and the fired `:web` artifact carries a
  bare `<img src>` of the original.

  The **original** itself is never touched — published snapshots point at it.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  require Logger

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

    with {:ok, %{width: width, height: height, variants: files} = result} <-
           ImageProcessor.process(path, ext, focal),
         variants = store_variants(files),
         :ok <- refuse_empty(variants, item) do
      previous = item.variants || %{}

      {:ok, _item} =
        CMS.update_media_item(
          item,
          %{
            width: width,
            height: height,
            variants: variants,
            # Rewritten every run, not merged (#1000): a libvips upgrade that
            # gains an encoder, or a re-crop that brings the source under a
            # dimension ceiling, has to be able to CLEAR a failure. A merged map
            # would remember "impossible" for ever and permanently opt the item
            # out of the repair it just became eligible for.
            variant_failures: failure_map(result)
          },
          authorize?: false,
          tenant: tenant
        )

      reclaim(previous, variants)
    else
      # Not a processable raster image, or a run that produced nothing — keep
      # what is already stored.
      _ -> :ok
    end
  end

  # A run that writes *no* variants for an item that has some is a failure, not
  # a result: an encoder that rejects a misconfigured quality fails every write,
  # and persisting that would empty the library one item at a time (and, with
  # the reclaim below, delete the blobs too). An item that legitimately has none
  # — a source narrower than every target — is unaffected: it had none before.
  defp refuse_empty(variants, item) do
    if variants == %{} and map_size(item.variants || %{}) > 0 do
      Logger.warning(
        "VariantWorker produced no variants for #{item.id}; keeping the existing set"
      )

      :error
    else
      :ok
    end
  end

  # Delete the blobs the replaced map named. Keys are regenerated per run, so
  # anything not in the new map is unreachable — orphaned storage that nothing
  # else in the system can find, since every other deletion path reads the
  # *current* map.
  defp reclaim(previous, current) do
    kept = current |> Map.values() |> MapSet.new(& &1["key"])

    for %{"key" => key} <- Map.values(previous),
        is_binary(key),
        not MapSet.member?(kept, key) do
      Storage.delete(key)
    end

    :ok
  end

  # `tmp` paths are server-built (System.tmp_dir! + a UUID), never user input —
  # so the File traversal warnings are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp(binary, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-variant-#{Ecto.UUID.generate()}#{ext}")
    File.write!(tmp, binary)
    tmp
  end

  # Each variant carries its own extension and content type now that one label
  # can exist in several encodings (#473) — the stored `content_type` is what a
  # `<picture>` `<source type=…>` needs, and reconstructing it from the key at
  # render time would put format knowledge in the templates.
  # `try/after` so a storage failure part-way through doesn't strand the
  # remaining temp files: one item now writes up to nine of them, and a bulk
  # regeneration during an S3 outage would otherwise fill the disk.
  # sobelow_skip ["Traversal.FileModule"]
  defp store_variants(files) do
    Map.new(files, fn variant ->
      %{label: label, path: tmp, width: w, height: h} = variant
      key = Storage.generate_key("#{label}#{variant.ext}")
      {:ok, ^key} = Storage.store(key, tmp)

      {label,
       %{
         "key" => key,
         "url" => Storage.url(key),
         "width" => w,
         "height" => h,
         "content_type" => variant.content_type
       }}
    end)
  after
    Enum.each(files, &rm(&1.path))
  end

  # `%{"webp" => reason}` for the full-size alternates this source cannot be
  # encoded to (#1000). The reason is not read by anything —
  # `Regeneration.current?/1` only asks whether a key is present — but an
  # operator looking at why an image has no WebP wants more than a boolean.
  #
  # One clause: `ImageProcessor.process/3` always reports `failed_full`, so a
  # defensive fallback here would be unreachable code that dialyzer (rightly)
  # rejects.
  defp failure_map(%{failed_full: failed}) when is_list(failed),
    do: Map.new(failed, &{to_string(&1), "encoder refused this source"})

  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)

  defp broadcast(id) do
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, @topic, {:media_processed, id})
  end
end
