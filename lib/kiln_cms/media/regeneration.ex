defmodule KilnCMS.Media.Regeneration do
  @moduledoc """
  Bulk re-enqueues `KilnCMS.Media.VariantWorker` over existing media (#473) —
  the "Regenerate Thumbnails" analogue.

  Needed twice over: once to roll modern formats out to media uploaded before
  #473, and then every time the variant configuration changes (a new target
  width, a different quality, AVIF switched on). Without it, a config change
  only ever reaches images uploaded after it.

  ## Why this enqueues rather than processes

  Every job re-fetches its original from storage, decodes it, and writes one
  file per label per format. Doing that inline would hold a request (or a Mix
  task's single process) for as long as the library is large, with no retry and
  no visibility. Enqueuing puts the work on the `:media` Oban queue, whose
  concurrency is what actually throttles it — so a regeneration of ten thousand
  images competes politely with live uploads instead of starving them.

  Jobs are enqueued **unique per media item** for an hour, so double-clicking
  the admin button, or running the task twice, doesn't double the work. The
  uniqueness key carries a `"source" => "regenerate"` marker so it dedupes
  against *other regeneration runs* only — Oban's default unique states include
  `:completed`, so without the marker every image uploaded in the previous hour
  would collide with its own upload job and be silently skipped.

  They also run at the lowest Oban priority. `:media` is a concurrency-3 queue
  shared with upload processing and video probes, and jobs are otherwise fetched
  in id order — so a ten-thousand-image run would sit ahead of every subsequent
  upload, leaving new images thumbnail-less for hours.

  ## What it never touches

  The stored original. Published snapshots and fired artifacts point at it by
  key, and a regeneration that rewrote originals would silently change what
  already-published documents serve. Variants are replaced wholesale by the worker,
  under fresh keys.
  """

  require Ash.Query

  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Media.VariantWorker

  # Rows pulled from the DB per round. Bounds the enqueuer's memory on a large
  # library; the Oban queue's own concurrency is what bounds the *work*.
  @batch 500

  # Long enough that a second run while the first is still draining is a no-op,
  # short enough that a genuine re-run after a config change isn't refused.
  @unique_period 3600

  # Distinguishes a regeneration job from the upload's own, so uniqueness
  # doesn't collide with a *completed* upload job (Oban's default unique states
  # include `:completed`).
  @source "regenerate"

  @doc """
  Enqueue a variant regeneration for every image in `org_id`. Returns
  `%{enqueued: n, scanned: n}`.

  ## Options

    * `:only_missing?` — skip items that already carry every configured
      alternate format. This is the safe default for a rollout: it does the
      work that is actually missing and costs nothing for media already
      converted. Pass `false` after a *quality* or *width* change, where the
      existing variants are present but wrong.
  """
  @spec run(Ash.UUID.t(), keyword()) :: %{enqueued: non_neg_integer(), scanned: non_neg_integer()}
  def run(org_id, opts \\ []) do
    only_missing? = Keyword.get(opts, :only_missing?, true)

    org_id
    |> stream_images()
    |> Enum.reduce(%{enqueued: 0, scanned: 0}, fn item, acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      if only_missing? and current?(item),
        do: acc,
        else: %{acc | enqueued: acc.enqueued + enqueue(item, org_id)}
    end)
  end

  @doc """
  Whether `item` already carries every configured alternate format for each of
  its responsive labels — i.e. whether a rollout run would skip it.

  "Current" has to mean *nothing a run would add*, not *has every format*, or
  the missing-only mode never converges: two shapes the pipeline itself produces
  can never carry an alternate, and a run that re-decodes them every time is a
  standing tax rather than a one-off rollout.
  """
  @spec current?(map()) :: boolean()
  # An animated source gets no alternates by design — its variants are already
  # flattened stills, so transcoding would spend encoder time on a second still
  # of an image whose animation is the point.
  def current?(%{content_type: "image/gif"}), do: true

  def current?(%{variants: variants}) when is_map(variants) and map_size(variants) > 0 do
    formats = KilnCMS.ImageProcessor.variant_formats()

    base_labels =
      variants
      |> Map.keys()
      |> Enum.map(&KilnCMS.ImageProcessor.base_label/1)
      |> Enum.uniq()

    Enum.all?(base_labels, fn label ->
      Enum.all?(formats, fn format ->
        # The source format has no suffix, so a label whose source *is* this
        # format counts as present under its bare key.
        Map.has_key?(variants, "#{label}.#{format}") or source_format?(variants, label, format)
      end)
    end)
  end

  # No variants at all. An image narrower than every responsive target
  # legitimately produces none, and re-decoding it forever to produce none again
  # is exactly the non-convergence above — so a *processed* item (one that has
  # its intrinsic width recorded) counts as current. An unprocessed one
  # (`width` still nil: mid-flight, or a failed run) is enqueued, which is the
  # case a rollout most wants to catch.
  def current?(%{width: width}) when is_integer(width), do: true
  def current?(_item), do: false

  defp source_format?(variants, label, format) do
    content_type = KilnCMS.ImageProcessor.variant_content_type("x.#{format}")

    case Map.get(variants, label) do
      %{"content_type" => ^content_type} -> true
      _other -> false
    end
  end

  # Keyset-free batching by id: media rows are immutable enough for this, and
  # ordering by id keeps the scan stable while jobs are being enqueued.
  defp stream_images(org_id) do
    Stream.resource(
      fn -> nil end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          case fetch_batch(org_id, cursor) do
            [] -> {:halt, :done}
            rows when length(rows) < @batch -> {rows, :done}
            rows -> {rows, List.last(rows).id}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_batch(org_id, cursor) do
    MediaItem
    |> Ash.Query.filter(like(content_type, "image/%"))
    |> after_cursor(cursor)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(@batch)
    |> Ash.Query.select([:id, :variants, :content_type, :width])
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: Ash.Query.filter(query, id > ^cursor)

  defp enqueue(item, org_id) do
    %{media_item_id: item.id, org_id: org_id, source: @source}
    |> VariantWorker.new(
      priority: 9,
      unique: [period: @unique_period, fields: [:args, :worker]]
    )
    |> Oban.insert()
    |> case do
      # A duplicate inside the unique window comes back as a conflicted job —
      # already scheduled, so it isn't counted as newly enqueued.
      {:ok, %Oban.Job{conflict?: true}} -> 0
      {:ok, _job} -> 1
      {:error, _reason} -> 0
    end
  end
end
