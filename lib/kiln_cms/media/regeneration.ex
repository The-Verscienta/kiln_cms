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

  def current?(%{variants: variants} = item) when is_map(variants) and map_size(variants) > 0 do
    formats = KilnCMS.ImageProcessor.variant_formats()
    failures = loaded_map(Map.get(item, :variant_failures))

    # `full` is deliberately excluded: `full_present?/2` below owns it, and the
    # two rules disagree. This sweep asks "does every label carry every format",
    # but `build_full/2` never writes a SOURCE-format full (the original is the
    # source-format full). So a WebP upload with `formats: [:webp, :avif]` gets
    # a `full.avif`, which makes `full` a base label, and the sweep then demands
    # a `full.webp` that will never exist — re-enqueuing it for ever.
    base_labels =
      variants
      |> Map.keys()
      |> Enum.map(&KilnCMS.ImageProcessor.base_label/1)
      |> Enum.reject(&(&1 == "full"))
      |> Enum.uniq()

    Enum.all?(base_labels, fn label ->
      Enum.all?(formats, fn format ->
        # The source format has no suffix, so a label whose source *is* this
        # format counts as present under its bare key. A format recorded as
        # impossible for THIS label (#1036) counts too, the same "present OR
        # recorded as impossible" rule `full_present?/2` already applies to
        # `full` — otherwise a label whose encoder genuinely can't produce a
        # format (not just `full`'s) re-enqueues for ever.
        key = "#{label}.#{format}"

        Map.has_key?(variants, key) or Map.has_key?(failures, key) or
          source_format?(variants, label, format)
      end)
    end)
    |> Kernel.and(full_present?(item, failures))
  end

  # No variants at all. Before #473 that was a legitimate terminal state: an
  # image narrower than every responsive target produced none, and re-decoding it
  # forever to produce none again is exactly the non-convergence above.
  #
  # `build_full/2` changed that and this clause did not follow (#919). A full-size
  # re-encode is unconditional on size, so any non-GIF source now yields at least
  # one `full.<format>` — and declaring such an item current made the
  # missing-only run, the documented rollout default, skip it for ever. A 150px
  # JPEG never got its WebP.
  #
  # So an empty map is current only when a run genuinely would add nothing.
  # `full_alternates/1` is `ImageProcessor`'s own answer to that, not a second
  # copy of the rule. (GIFs never reach here — the `content_type` clause above
  # matches first.)
  def current?(%{variants: variants, width: width} = item)
      when is_map(variants) and map_size(variants) == 0 and is_integer(width),
      do: full_present?(item, loaded_map(Map.get(item, :variant_failures)))

  # Unprocessed (`width` still nil: mid-flight, or a failed run) is enqueued,
  # which is the case a rollout most wants to catch.
  def current?(%{width: width}) when is_integer(width), do: true
  def current?(_item), do: false

  # The `base_labels` sweep above only asks whether the labels that ALREADY
  # exist carry every format — so an item missing the `full` label entirely
  # passes it without ever being asked about the one write that is
  # unconditional (#1000).
  #
  # `build_full/2` writes a full-size alternate whatever the source's size, so
  # every non-GIF item should have one per configured alternate format. An item
  # that lost only `full.webp` — the largest write, and the first to fail on
  # ENOSPC or an encoder OOM — therefore read as current, and the missing-only
  # run (the documented rollout default) reported `enqueued: 0` for it for ever.
  # Since #919 that also costs the item its whole `<picture>` `<source>`.
  #
  # A bare key check would break the convergence this module exists to protect:
  # a panorama past libvips' WebP dimension ceiling can never gain one, and
  # re-decoding it every run is the standing tax the moduledoc warns about. So a
  # format counts as satisfied when it is present OR recorded as impossible —
  # which is what `variant_failures` is for.
  defp full_present?(item, failures) do
    variants = loaded_map(Map.get(item, :variants))

    item
    |> Map.get(:content_type)
    |> KilnCMS.ImageProcessor.full_alternates()
    |> Enum.all?(fn format ->
      key = "full.#{format}"
      Map.has_key?(variants, key) or Map.has_key?(failures, key)
    end)
  end

  # `%Ash.NotLoaded{}` is a struct, so it passes both `is_map/1` and a `%{} = x`
  # match — the two ways this would otherwise be mistaken for an empty map. Named
  # explicitly so a future `select/2` that forgets an attribute fails visibly in
  # a test rather than silently answering "nothing recorded".
  defp loaded_map(%Ash.NotLoaded{}), do: %{}
  defp loaded_map(map) when is_map(map), do: map
  defp loaded_map(_other), do: %{}

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
    # `:variant_failures` is not optional here. An UNSELECTED Ash attribute
    # arrives as `%Ash.NotLoaded{}`, which is truthy — so a `|| %{}` fallback
    # does not fire, `Map.has_key?/2` answers false for every format, and every
    # recorded failure silently reads as "never recorded". That made the whole
    # of #1000 inert on this path, which is the only path `run/2` uses.
    |> Ash.Query.select([:id, :variants, :variant_failures, :content_type, :width])
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
