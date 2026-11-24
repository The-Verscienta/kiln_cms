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

    * The private blob cannot be read at all. If it is definitely missing
      (`:enoent`, a `404`), there is nothing to strip: the job completes and
      the reaper takes the row. Any other read error (a timeout, a `5xx`, a
      full temp disk) is returned as `{:error, _}` so Oban retries (#2723);
      if every attempt fails, the row stays quarantined for the reaper.
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
      purged, then its private blob deleted, an error logged naming the item —
      the same answer the sync path gives at upload time, delivered late. If
      the purge fails the blob is kept and the job fails, so Oban redoes the
      refusal (#2835). Otherwise the upload is promoted **as it arrived**,
      with the same warning the sync path logs, because "can never be
      uploaded at all" is the worse of the two bad answers for a host that
      will never remux.
    * The item is gone, or no longer quarantined — someone deleted it, or a
      duplicate job ran — nothing to do.
    * The row is purged **while** the strip runs, after the copy reached the
      public key (#3068): the release comes back stale, and once a re-read
      finds no row at all, live or trashed, the job deletes that public copy
      and the private upload, logs that it withdrew them, and completes. The
      key is never put in the job's args for a retry to clean up: a job that
      names a key to delete is a delete primitive.

  Everything an Oban retry could double is idempotent: promotion is a `store`
  to a key that either has the stripped copy or nothing; release is a flag;
  the private delete tolerates a missing blob.
  """
  use Oban.Worker, queue: :media, max_attempts: 5

  alias KilnCMS.{AVProcessor, CMS, Media, Storage}
  alias KilnCMS.Media.Ingest

  import Ecto.Query, only: [from: 2]

  require Logger

  # The strip is bounded by ffmpeg's own `-timelimit` (see `AVProcessor`); this
  # bounds the job around it plus the two storage copies of a file up to the
  # 500 MB video cap.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => id} = args}) do
    # The item's site (epic #336); a job without `org_id` is cancelled with a
    # logged error (#1658).
    with {:ok, tenant} <- Ingest.job_tenant(args, __MODULE__) do
      # As the media pipeline's system actor (#1659), and `authorize_with:
      # :error`: a quarantined row is readable by editors and the pipeline
      # only, so a refused read would filter to "gone" — and a job that
      # answered that with `:ok` would leave the upload quarantined until the
      # reaper deleted it. A refusal fails the job instead.
      case CMS.get_media_item(id, actor: Media.system(), authorize_with: :error, tenant: tenant) do
        {:ok, %{quarantined: true, storage_key: key} = item} when is_binary(key) ->
          strip(item, key, args, tenant)

        {:error, %Ash.Error.Forbidden{} = error} ->
          Logger.error(
            "Deferred metadata strip for media #{id}: refused a read: #{inspect(error)}"
          )

          {:error, error}

        # Gone, or already released — a retried job after success, say.
        _other ->
          :ok
      end
    end
  end

  defp strip(item, key, args, tenant) do
    ext = args["ext"] || Path.extname(key)

    case download(item, key, ext) do
      {:ok, original} ->
        try do
          strip_downloaded(item, key, original, ext, args["max_bytes"], tenant)
        after
          rm(original)
        end

      # The site's store (#1559) could not be resolved: the blob is there, the
      # way to it is not. Retry rather than leave the row to the reaper.
      {:error, {:site_storage, _reason} = reason} ->
        Logger.warning(
          "Deferred metadata strip for media #{item.id}: its store is unavailable (#{inspect(reason)}); will retry."
        )

        {:error, reason}

      # The private blob is definitely not there to strip. Nothing this job
      # can do; the reaper takes the row.
      {:error, reason} = error ->
        if Storage.not_found?(reason) do
          Logger.error(
            "Deferred metadata strip for media #{item.id}: private blob unreadable (#{inspect(reason)})"
          )

          :ok
        else
          # Anything else may pass (#2723): a timeout or 5xx from the object
          # store, a full temp disk. Completing here would leave a good upload
          # to the reaper; retrying costs a few attempts at most, and if they
          # all fail the row ends with the reaper exactly as before, just later.
          # Shapes no retry can fix (`:invalid_key`,
          # `:private_storage_not_configured`) end the same way. What counts
          # as missing is `Storage.not_found?/1`'s call.
          Logger.warning(
            "Deferred metadata strip for media #{item.id}: could not read its private blob " <>
              "(#{inspect(reason)}); will retry."
          )

          error
        end
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
         {:ok, ^key} <- Storage.store(key, stripped, item),
         {:ok, released} <- release_or_withdraw(item, key, stripped_size(stripped), tenant) do
      Storage.delete_private(key, item)
      Ingest.enqueue_processing(released)
      broadcast(item.id)
      :ok
    else
      # Purged while the strip ran, or held by someone else: see
      # `release_or_withdraw/4`.
      :ok ->
        :ok

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

      with {:ok, ^key} <- Storage.store(key, original, item),
           {:ok, released} <- release_or_withdraw(item, key, nil, tenant) do
        Storage.delete_private(key, item)
        Ingest.enqueue_processing(released)
        broadcast(item.id)
        :ok
      else
        :ok ->
          :ok

        other ->
          Logger.error("Deferred A/V promotion for media #{item.id} failed: #{inspect(other)}")
          {:error, other}
      end
    end
  end

  # Row and blob both go: a refused upload must not linger as a quarantined
  # row (the reaper would take it eventually, but "refused" should mean now).
  #
  # Row first, blob only once the row is gone (#2835), as the admin purge in
  # `MediaLive` does. The pipeline may purge an item only while it is
  # quarantined (#1659), through `:purge_quarantined` (#2610). A purge that
  # fails, for any reason, keeps the blob with its row and fails the job, so
  # Oban redoes the refusal within minutes; the reaper is the backstop if it
  # never succeeds.
  defp refuse(item, key, tenant, why) do
    Logger.error(
      "Media #{item.id} (#{item.filename}) refused: #{why}. Re-export and upload again."
    )

    case CMS.purge_quarantined_media_item(item, actor: Media.system(), tenant: tenant) do
      :ok ->
        delete_private(item, key)
        broadcast(item.id)
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Refused media #{item.id} could not be purged: #{inspect(reason)}; its private blob is kept."
        )

        error
    end
  end

  # After a purge: a failure here leaves a private blob with no row, which
  # nothing sweeps. Logged with the key so an operator can remove it.
  defp delete_private(item, key) do
    case Storage.delete_private(key, item) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Purged media #{item.id} left its private blob #{key} behind: #{inspect(reason)}"
        )
    end
  end

  # The release, unless the row went while the strip ran (#3068). The public
  # copy is already stored by then, so a row the reaper or an admin purged
  # meanwhile would leave that copy served at a URL nothing records. A purge
  # shows up as a `StaleRecord` on the release; the row is then re-read, and
  # the copy withdrawn only if no row of any kind is left. Anything else
  # fails the job as before.
  #
  # `{:ok, released}` continues the promotion; `:ok` means there is nothing
  # left for this job to do.
  defp release_or_withdraw(item, key, byte_size, tenant) do
    case release(item, byte_size, tenant) do
      {:ok, released} ->
        {:ok, released}

      {:error, error} ->
        if stale?(error), do: withdraw_if_gone(item, key, tenant), else: {:error, error}
    end
  end

  @doc false
  # After a stale release: withdraw the copy this job promoted to `key`, but
  # only when the row is gone. A row that `:read` still finds is someone
  # else's to finish (a duplicate job released it). A row only the trash
  # holds keeps its blobs too: a trashed item can be restored, and today a
  # trashed row is simply released, so a stale release on one would mean a
  # filter added to `:release_quarantine` later. Public only so a test can
  # drive that branch, which no release reaches today.
  @spec withdraw_if_gone(struct(), String.t(), String.t()) :: :ok | {:error, term()}
  def withdraw_if_gone(item, key, tenant) do
    case CMS.get_media_item(item.id,
           actor: Media.system(),
           authorize_with: :error,
           tenant: tenant
         ) do
      {:ok, _live} ->
        :ok

      {:error, error} ->
        cond do
          not not_found?(error) ->
            Logger.error(
              "Deferred metadata strip for media #{item.id}: its release was stale and its " <>
                "row could not be re-read (#{inspect(error)}); the copy at its public key " <>
                "#{key} is kept."
            )

            {:error, error}

          row_exists?(item) ->
            :ok

          true ->
            withdraw(item, key)
        end
    end
  end

  # Any row with this id, trashed included. `:read` hides a trashed row, and
  # `:trashed` is admin-only (the pipeline's actor may not read it), so this
  # asks the table directly. It answers only "is there a row", for an id this
  # job already read under its own org.
  defp row_exists?(item) do
    KilnCMS.Repo.exists?(
      from(m in "media_items",
        where: m.id == type(^item.id, :binary_id) and m.org_id == type(^item.org_id, :binary_id)
      )
    )
  end

  # Both copies go: the public one this job stored, and the private upload,
  # in case the purger's own delete of it failed. The key is a write-once
  # UUID whose row is gone, so nothing else can be using it. A failed delete
  # is logged with the key for an operator, as the purge paths do.
  defp withdraw(item, key) do
    for {what, result} <- [
          {"public copy", Storage.delete(key, item)},
          {"private blob", Storage.delete_private(key, item)}
        ],
        result != :ok do
      Logger.error("Purged media #{item.id} left its #{what} #{key} behind: #{inspect(result)}")
    end

    Logger.warning(
      "Media #{item.id} was purged while its strip ran; withdrew the copy at its public key #{key}."
    )

    :ok
  end

  defp stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale?(_error), do: false

  defp not_found?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found?(_error), do: false

  defp release(item, byte_size, tenant) do
    attrs = if byte_size, do: %{byte_size: byte_size}, else: %{}

    CMS.release_media_quarantine(item, attrs, actor: Media.system(), tenant: tenant)
  end

  defp download(item, key, ext) do
    tmp = Path.join(System.tmp_dir!(), "kiln-avstrip-#{Ecto.UUID.generate()}#{ext}")

    case Storage.copy_to_file(key, tmp, private?: true, at: item) do
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
