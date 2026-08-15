defmodule KilnCMS.Media.AVStripWorker do
  @moduledoc """
  The deferred half of the A/V metadata strip (#1122): takes a **quarantined**
  `MediaItem` — an audio/video upload `KilnCMS.Media.Ingest` staged into
  private storage as it arrived — strips its container metadata with the same
  `KilnCMS.AVProcessor.strip_metadata/2` the synchronous path uses, promotes
  the stripped copy to the item's public key, releases the quarantine, and
  only then enqueues derivation (`AVWorker` — probe, poster).

  ## Why the order is strip → promote → release → derive

  Each step makes the next one safe:

    * **Promote before release.** The row's `url` is `Storage.url(key)` from
      the moment it is created; what keeps that URL from serving the
      unstripped upload is that nothing is at the public key until the
      *stripped* copy is put there. Releasing first would open a window in
      which the policy lets the row through and the URL 404s — harmless — but
      releasing before promoting is the wrong order to get used to.
    * **Release before derive.** `AVWorker` and `VariantWorker` fetch the
      original from *public* storage on any node; enqueued earlier they would
      find nothing (or, worse, be given a private key to read). So derivation
      is this worker's to enqueue, after promotion, and `Ingest.create_item/5`
      deliberately does not do it for a quarantined row.
    * **Delete the private blob last.** A failed promotion must leave the
      upload where it can be retried, not gone.

  ## Failure, and what each kind does

  The strip's outcomes are the sync path's, applied one step later:

    * `{:ok, stripped}` — promoted, released, derived. The stripped copy is
      re-checked against the item's size cap first, as `Ingest.persist/4`
      does: a remux is not size-preserving in the safe direction.
    * `{:error, :insufficient_space}` / `{:error, :timeout}` — transient;
      returned as `{:error, _}` so Oban retries with backoff. If it never
      succeeds the row stays quarantined and `KilnCMS.Media.QuarantineReaper`
      removes it after its window.
    * `{:error, :unavailable}` (no ffmpeg) or another remux failure — a
      standing property of the host or the file, so retrying is pointless.
      Under `require_av_metadata_strip: true` the upload is **refused**: row
      purged, private blob deleted, an error logged naming the item — the same
      answer the sync path gives at upload time, delivered late. Otherwise the
      upload is promoted **as it arrived**, with the same warning the sync path
      logs, because "can never be uploaded at all" is the worse of the two bad
      answers for a host that will never remux.
    * The item is gone, or no longer quarantined — someone deleted it, or a
      duplicate job ran — nothing to do.

  Everything an Oban retry could double is idempotent: promotion is a `store`
  to a key that either has the stripped copy or nothing; release is a flag;
  the private delete tolerates a missing blob.
  """
  use Oban.Worker, queue: :media, max_attempts: 5

  alias KilnCMS.{AVProcessor, CMS, Storage}
  alias KilnCMS.Media.Ingest

  require Logger

  # The strip is bounded by ffmpeg's own `-timelimit` (see `AVProcessor`); this
  # bounds the job around it plus the two storage copies of a file up to the
  # 500 MB video cap.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => id} = args}) do
    tenant = args["org_id"]

    case CMS.get_media_item(id, authorize?: false, tenant: tenant) do
      {:ok, %{quarantined: true, storage_key: key} = item} when is_binary(key) ->
        strip(item, key, args, tenant)

      # Gone, or already released — a retried job after success, say.
      _other ->
        :ok
    end
  end

  defp strip(item, key, args, tenant) do
    ext = args["ext"] || Path.extname(key)

    case download(key, ext) do
      {:ok, original} ->
        try do
          strip_downloaded(item, key, original, ext, args["max_bytes"], tenant)
        after
          rm(original)
        end

      # The private blob is not there to strip. Nothing this job can do; the
      # reaper takes the row.
      {:error, reason} ->
        Logger.error(
          "Deferred metadata strip for media #{item.id}: private blob unreadable (#{inspect(reason)})"
        )

        :ok
    end
  end

  defp strip_downloaded(item, key, original, ext, max_bytes, tenant) do
    case AVProcessor.strip_metadata(original, ext) do
      {:ok, stripped} ->
        try do
          promote_stripped(item, key, stripped, max_bytes, tenant)
        after
          rm(stripped)
        end

      {:error, transient} when transient in [:insufficient_space, :timeout] ->
        Logger.warning(
          "Deferred metadata strip for media #{item.id} hit #{inspect(transient)}; will retry."
        )

        {:error, transient}

      {:error, reason} ->
        promote_unstripped_or_refuse(item, key, original, reason, tenant)
    end
  end

  defp promote_stripped(item, key, stripped, max_bytes, tenant) do
    with :ok <- check_size(stripped, max_bytes),
         {:ok, ^key} <- Storage.store(key, stripped),
         {:ok, released} <- release(item, stripped_size(stripped), tenant) do
      Storage.delete_private(key)
      Ingest.enqueue_processing(released)
      broadcast(item.id)
      :ok
    else
      {:error, :too_large} ->
        # Same refusal as the sync path, one step later: the remux grew past
        # the ceiling `max_upload_size/0` advertises.
        refuse(item, key, tenant, "its remuxed copy exceeds the size cap")

      {:error, reason} ->
        Logger.error(
          "Deferred metadata strip for media #{item.id} could not promote: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "Deferred metadata strip for media #{item.id} could not promote: #{inspect(other)}"
        )

        {:error, other}
    end
  end

  # The sync path's `store_unstripped_av/6`, one step later.
  defp promote_unstripped_or_refuse(item, key, original, reason, tenant) do
    if require_av_strip?() do
      Logger.warning(
        "Refused A/V upload #{item.id} (#{item.filename}): metadata could not be stripped " <>
          "(#{inspect(reason)}) and require_av_metadata_strip is on."
      )

      refuse(item, key, tenant, "its metadata could not be stripped")
    else
      Logger.warning(
        "Storing #{item.filename} with its container metadata intact: #{inspect(reason)}. " <>
          "Set require_av_metadata_strip: true to refuse such uploads instead."
      )

      with {:ok, ^key} <- Storage.store(key, original),
           {:ok, released} <- release(item, nil, tenant) do
        Storage.delete_private(key)
        Ingest.enqueue_processing(released)
        broadcast(item.id)
        :ok
      else
        other ->
          Logger.error("Deferred A/V promotion for media #{item.id} failed: #{inspect(other)}")
          {:error, other}
      end
    end
  end

  # Row and blob both go: a refused upload must not linger as a quarantined
  # row (the reaper would take it eventually, but "refused" should mean now).
  defp refuse(item, key, tenant, why) do
    Logger.error(
      "Media #{item.id} (#{item.filename}) refused: #{why}. Re-export and upload again."
    )

    Storage.delete_private(key)
    CMS.purge_media_item(item, authorize?: false, tenant: tenant)
    broadcast(item.id)
    :ok
  end

  defp release(item, byte_size, tenant) do
    attrs = if byte_size, do: %{byte_size: byte_size}, else: %{}

    item
    |> Ash.Changeset.for_update(:release_quarantine, attrs, authorize?: false, tenant: tenant)
    |> Ash.update()
  end

  defp download(key, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-avstrip-#{Ecto.UUID.generate()}#{ext}")

    case Storage.copy_to_file(key, tmp, private?: true) do
      :ok ->
        {:ok, tmp}

      {:error, reason} ->
        rm(tmp)
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp check_size(_path, nil), do: :ok

  defp check_size(path, max) when is_integer(max) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max -> :ok
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stripped_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp require_av_strip?,
    do: Application.get_env(:kiln_cms, :require_av_metadata_strip, false) == true

  # Both paths are server-built temp files.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)

  # Same topic `AVWorker`/`VariantWorker` broadcast on, so an open library
  # refreshes as the item leaves quarantine (or is refused).
  defp broadcast(id) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMS.Media.VariantWorker.topic(),
      {:media_processed, id}
    )
  end
end
