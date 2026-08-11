defmodule KilnCMS.Media.AVWorker do
  @moduledoc """
  Probes a freshly-uploaded video/audio `MediaItem` for duration and
  dimensions, and extracts a poster frame from a video (#494).

  The A/V counterpart of `KilnCMS.Media.VariantWorker`, and deliberately the
  same shape: `MediaLive` stores the original and creates the row, then
  enqueues this worker with just the item id; the worker **re-fetches the
  original from storage** into a temp file (so the job runs correctly on any
  node), runs `KilnCMS.AVProcessor` over it, writes the result back, and
  broadcasts on the shared `"media:updated"` topic so an open media library
  refreshes live.

  ## Everything here is optional

  `AVProcessor` shells out to ffprobe/ffmpeg, which are a *system* dependency
  this application does not declare. With them absent — the default on a bare
  deployment — every step below no-ops and the job succeeds: the upload is
  stored and playable, it just has no duration and no generated poster. That
  is why nothing here returns an error for a missing binary, and why the
  editor can always set a poster image by hand.

  ## No poster for a gated item

  A poster is written to *public* storage (it renders as a plain `<img>`), so
  it is only generated for a `:public` item. Gating an item later deletes any
  poster it already has — see `KilnCMS.CMS.Changes.MigrateMediaStorage`.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias KilnCMS.{AVProcessor, CMS, Storage}

  require Logger

  @doc """
  Hard ceiling on a single job, enforced by Oban — so one bad upload can't
  hold a `:media` queue slot indefinitely.

  This bounds the **job**, not the external process. Closing an Erlang port
  does not signal the OS child it spawned; it only closes the pipes, and an
  ffmpeg spinning on CPU without writing to stdout never notices. The bound
  that actually applies to ffmpeg is its own `-timelimit`, passed by
  `KilnCMS.AVProcessor` — see the note there.
  """
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => id} = args}) do
    tenant = args["org_id"]

    case CMS.get_media_item(id, authorize?: false, tenant: tenant) do
      {:ok, %{storage_key: key} = item} when is_binary(key) -> process(item, key, tenant)
      _ -> :ok
    end
  end

  defp process(item, key, tenant) do
    case download(item, key, Path.extname(key)) do
      {:ok, tmp} ->
        try do
          analyze(item, tmp, tenant)
        after
          rm(tmp)
        end

        broadcast(item.id)
        :ok

      # Original isn't readable (e.g. removed) — nothing to do.
      {:error, _reason} ->
        :ok
    end
  end

  # Copies the original to a temp file via `Storage.copy_to_file/3`, which
  # streams it a chunk at a time rather than materializing the whole blob:
  # `MediaLive` accepts video up to 500 MB and the `:media` queue runs several
  # jobs at once, so a `fetch/1` here would put gigabytes on the background
  # heap for the largest uploads.
  #
  # `tmp` is server-built (System.tmp_dir! + a UUID), never user input — the
  # File traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp download(item, key, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-av-#{Ecto.UUID.generate()}#{ext}")

    # A gated item's bytes live in private storage; the ordinary case is public.
    case Storage.copy_to_file(key, tmp, private?: item.audience != :public) do
      :ok ->
        {:ok, tmp}

      {:error, reason} ->
        rm(tmp)
        {:error, reason}
    end
  end

  defp analyze(item, path, tenant) do
    case AVProcessor.probe(path) do
      {:ok, probed} ->
        attrs =
          %{}
          |> put_duration(probed)
          |> put_dimensions(probed)
          |> put_poster(item, path, probed)

        {:ok, written} = CMS.update_media_item(item, attrs, authorize?: false, tenant: tenant)
        revoke_poster_if_gated(written, tenant)

      # No ffprobe, or a container it couldn't read. Either way there is
      # nothing to write and the upload stands on its own.
      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Revokes a poster frame that landed on an item which is (now) gated —
  deleting its public blob and clearing `variants`.

  Public only because it is a security property worth testing directly: with
  no ffmpeg installed there is no other way to reach it, and "a still of a
  members-only video stayed world-readable" is not a thing to leave uncovered.
  Called by this module at the end of every successful write.
  """
  # Closes the race between this job and an editor gating the item.
  #
  # `item.audience` was read when the job started; extracting a poster from a
  # large video takes long enough for someone to gate it in the meantime.
  # `MigrateMediaStorage` clears `variants` from the row it sees, so a gate
  # that lands BEFORE this write clears an empty map and then this write puts
  # a public poster back — a still of a members-only video, world-readable at
  # a URL nothing will ever clean up. That is precisely the leak gating is
  # supposed to prevent.
  #
  # So the write is followed by a re-read: if the item is gated by the time it
  # lands, the poster is revoked and its blob deleted. Ordering it *after* the
  # write is what makes it total — whichever of the two operations went second
  # is the one that fixes it up.
  @spec revoke_poster_if_gated(struct(), String.t() | nil) :: :ok
  def revoke_poster_if_gated(%{audience: :public}, _tenant), do: :ok

  def revoke_poster_if_gated(item, tenant) do
    case item.variants || %{} do
      # Nothing to revoke: the gate already ran and this write added no poster.
      empty when map_size(empty) == 0 ->
        :ok

      variants ->
        for {_label, %{"key" => key}} <- variants, is_binary(key), do: Storage.delete(key)

        {:ok, _cleared} =
          CMS.update_media_item(item, %{variants: %{}}, authorize?: false, tenant: tenant)

        :ok
    end
  end

  # Omitted rather than written as nil when ffprobe couldn't measure it
  # ("N/A" for some streams). This worker has `max_attempts: 3`, so a retry
  # that probes less successfully than the first attempt must not erase a
  # duration the first attempt got right — the same rule the dimensions below
  # follow.
  defp put_duration(attrs, %{duration: seconds}) when is_number(seconds),
    do: Map.put(attrs, :duration_seconds, seconds)

  defp put_duration(attrs, _probed), do: attrs

  # Audio has no dimensions, and writing nil over an existing width/height
  # would be a silent downgrade if this ever re-ran on an item that had them.
  defp put_dimensions(attrs, %{video?: true, width: w, height: h})
       when is_integer(w) and is_integer(h),
       do: Map.merge(attrs, %{width: w, height: h})

  defp put_dimensions(attrs, _probed), do: attrs

  defp put_poster(attrs, %{audience: :public} = item, path, %{video?: true} = probed) do
    case AVProcessor.poster(path, probed.duration) do
      {:ok, poster_path} ->
        try do
          Map.put(attrs, :variants, store_poster(item, poster_path, probed))
        after
          rm(poster_path)
        end

      {:error, _reason} ->
        attrs
    end
  end

  defp put_poster(attrs, _item, _path, _probed), do: attrs

  # Merged into the existing map rather than replacing it: `variants` is
  # shared with the image pipeline, and a future second A/V artifact
  # shouldn't have to know it is the only writer.
  defp store_poster(item, poster_path, probed) do
    key = Storage.generate_key_with_ext(".jpg")

    case Storage.store(key, poster_path) do
      {:ok, ^key} ->
        poster = %{
          "key" => key,
          "url" => Storage.url(key),
          "width" => probed.width,
          "height" => probed.height
        }

        Map.put(item.variants || %{}, AVProcessor.poster_label(), poster)

      other ->
        Logger.warning("AVWorker couldn't store a poster for #{item.id}: #{inspect(other)}")
        item.variants || %{}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)

  # The same topic `Media.VariantWorker` broadcasts on — the media library
  # subscribes once and doesn't care which worker finished.
  defp broadcast(id) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMS.Media.VariantWorker.topic(),
      {:media_processed, id}
    )
  end
end
