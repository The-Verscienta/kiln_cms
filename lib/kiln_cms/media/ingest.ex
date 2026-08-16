defmodule KilnCMS.Media.Ingest do
  @moduledoc """
  Taking a file on local disk into the media library: sniff → size-cap →
  strip → store → `MediaItem` → enqueue derivation.

  This pipeline used to live twice inside `KilnCMSWeb.MediaLive` (once for a
  direct upload, once for an Unsplash import). The bulk importers (#487) are the
  third caller, and the sequence is one where a divergence is silent rather than
  loud — an ingest path that forgets `strip_metadata/2` still produces a working
  image, it just ships the photographer's GPS coordinates with it, and one that
  forgets `enqueue_processing/1` still produces a working item, it just never
  gets variants and renders full-size forever. So it lives here once.

  ## What it decides, and what it doesn't

  The **kind** of a file is decided by byte-sniffing, never by its name or the
  `Content-Type` a server claimed: `ImageProcessor` first, then `AVProcessor`,
  then `DocumentProcessor`, and a file none of them recognise is refused. The
  per-kind size caps are the same ones the upload UI enforces, applied to the
  bytes actually received rather than to any declared length.

  What it does *not* decide is authorization: `create_media_item` runs under the
  `:actor`/`:tenant` the caller passes, so an ingest can never write a media item
  the caller couldn't have created by hand.

  ## Fetching

  `store_url/2` exists for the importers, which are handed URLs by a file the
  user uploaded — i.e. attacker-influenced input pointed at this server's own
  network position. It therefore runs every URL through
  `KilnCMS.SafeFetch` — which resolves the host once, checks the answer, and
  connects to that *literal address*, so the name cannot be re-resolved to
  `169.254.169.254` between the check and the connection. It is the only place
  in the ingest path that touches the network.
  """

  require Logger

  alias KilnCMS.AVProcessor
  alias KilnCMS.CMS
  alias KilnCMS.DocumentProcessor
  alias KilnCMS.ImageProcessor
  alias KilnCMS.MediaKind
  alias KilnCMS.SafeFetch
  alias KilnCMS.Storage
  alias KilnCMS.Webhooks.SafeUrl

  # The same ceilings the media library enforces — see KilnCMSWeb.MediaLive,
  # which now delegates here rather than restating them.
  @max_image_size 10_000_000
  @max_document_size 25_000_000
  @max_video_size 500_000_000
  @max_audio_size 100_000_000
  @max_captions_size 2_000_000

  # Deliberately the DOCUMENT cap, not the upload ceiling. A sideloaded body is
  # buffered in memory (`SafeFetch` returns a binary), and what an importer
  # pulls is page imagery — accepting a 500 MB video over HTTP from a site being
  # migrated away from would be a memory hazard in exchange for a case nobody
  # has. Anything larger is reported as a skipped asset, which is visible.
  @max_download_size @max_document_size
  @download_timeout 30_000

  @type opts :: [
          actor: term(),
          tenant: term(),
          alt: String.t() | nil,
          caption: String.t() | nil,
          max_bytes: pos_integer()
        ]

  @doc """
  Ingest the file at `path`, recording it as `filename`.

  `path` is expected to be a server-generated temp file — a LiveView upload, or
  something `store_url/2` downloaded. The caller owns it and cleans it up; this
  function never removes it (it may create and remove a stripped *copy*).

  Returns the created `MediaItem`. On any failure the stored blob is removed
  again, so a failed ingest leaves no orphan in the bucket.

  `:max_bytes` overrides the per-kind cap. It exists because the caps are the
  *upload UI's* limits, and not every caller is an upload: the Unsplash import
  fetches a full-resolution original (routinely 10-20 MB) that no editor can
  shrink, and it had no cap at all before this pipeline was shared.
  """
  @spec store_file(Path.t(), String.t(), opts()) :: {:ok, struct()} | {:error, term()}
  def store_file(path, filename, opts \\ []) when is_binary(path) and is_binary(filename) do
    with {:ok, kind} <- classify(path),
         :ok <- check_size(path, Keyword.get(opts, :max_bytes) || cap_for(kind)) do
      persist(path, kind, filename, opts)
    end
  end

  @doc """
  Download `url` and ingest it under the filename its path implies.

  Returns `{:error, {:unsafe_url, reason}}` for a URL that fails the SSRF
  checks, and `{:error, {:http_status, status}}` / `{:error, :too_large}` for a
  fetch that did not produce a usable body. Importers treat every one of these
  as "skip this asset and carry on", never as a reason to abandon the run.
  """
  @spec store_url(String.t(), opts()) :: {:ok, struct()} | {:error, term()}
  # `path` is this module's own `download/1` temp file (a UUID under tmp_dir),
  # never caller input — the traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  def store_url(url, opts \\ []) when is_binary(url) do
    with :ok <- safe_url(url),
         {:ok, path} <- download(url) do
      try do
        store_file(path, filename_from_url(url), opts)
      after
        File.rm(path)
      end
    end
  end

  @doc """
  Queue background derivation for `item` — variants for an image, poster/probe
  for A/V, nothing for a document or caption track (neither has anything to
  derive).

  Public because a caller that creates a `MediaItem` by some other route still
  owes it this call.
  """
  @spec enqueue_processing(struct()) :: :ok
  def enqueue_processing(item) do
    # Carry the item's org so the worker re-fetches/updates under its tenant
    # (epic #336) — future-proof for the strict `global?: false` flip.
    args = %{media_item_id: item.id, org_id: item.org_id}

    # `insert/1`, not `insert!/1`. A bulk import calls this thousands of times
    # from a mix task; one Oban/DB hiccup raising here would abort the run
    # before its report is printed, losing the record of everything already
    # created. A missing derivation job costs variants, which are re-derivable.
    cond do
      MediaKind.playable?(item.content_type) ->
        insert_job(KilnCMS.Media.AVWorker.new(args), item)

      MediaKind.of(item.content_type) == :image ->
        insert_job(KilnCMS.Media.VariantWorker.new(args), item)

      true ->
        :ok
    end
  end

  defp insert_job(changeset, item) do
    case Oban.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Media #{item.id} stored but derivation was not queued: #{inspect(reason)}. " <>
            "Re-queue images with mix kiln.media.regenerate_variants; an A/V item " <>
            "has no bulk recovery path and must be re-uploaded."
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("Media #{item.id} stored but derivation was not queued: #{inspect(error)}")
      :ok
  end

  @doc "The per-kind byte ceiling, exposed so callers can advertise the same numbers."
  @spec max_upload_size() :: pos_integer()
  def max_upload_size, do: @max_video_size

  # ── Classification ─────────────────────────────────────────────────────────

  # Byte-sniffed, in the same order the upload path tries: an image is the
  # common case, and only a file no processor recognises is refused.
  defp classify(path) do
    case ImageProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        {:ok, %{kind: :image, ext: ext, content_type: content_type}}

      {:error, _reason} ->
        classify_av(path)
    end
  end

  defp classify_av(path) do
    case AVProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type, kind: kind}} ->
        {:ok, %{kind: kind, ext: ext, content_type: content_type}}

      {:error, _reason} ->
        classify_document(path)
    end
  end

  defp classify_document(path) do
    case DocumentProcessor.validate_upload(path) do
      {:ok, %{ext: ext, content_type: content_type}} ->
        {:ok, %{kind: :document, ext: ext, content_type: content_type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Takes the classification MAP, and every clause says so — including the
  # document one, which used to be a bare catch-all.
  #
  # That catch-all was a trap: `cap_for(:video)` (the kind atom, an easy thing
  # to reach for, and a mistake #820 actually made) matched it silently and
  # capped video at the 25 MB document limit, refusing every video above it.
  # A wrong-shaped call now raises instead of quietly returning the smallest
  # cap in the module.
  defp cap_for(%{kind: :image}), do: @max_image_size
  defp cap_for(%{kind: :video}), do: @max_video_size
  defp cap_for(%{kind: :audio}), do: @max_audio_size
  defp cap_for(%{kind: :captions}), do: @max_captions_size
  defp cap_for(%{kind: :document}), do: @max_document_size

  # Measured from the RECEIVED FILE, never from a declared length: the caller's
  # own transport may enforce only one outer ceiling, so trusting a claimed size
  # would make every tighter per-kind cap here advisory.
  #
  # `path` is always a server-generated temp file.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_size(path, max) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= max -> :ok
      {:ok, _stat} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Store ──────────────────────────────────────────────────────────────────

  # `source`, when removed, is the server-built stripped temp file produced by
  # `ImageProcessor.strip_metadata/2` (a UUID path), never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, %{kind: :image, ext: ext, content_type: content_type}, filename, opts) do
    # Strip EXIF/GPS before persisting (#215). On any strip failure fall back to
    # the original so a valid file still saves.
    {source, stripped?} = stripped_source(path, ext)

    try do
      store_and_create(source, ext, content_type, filename, opts)
    after
      if stripped?, do: File.rm(source)
    end
  end

  # PDFs carry author/producer in `/Info` and an XMP packet (#807), so strip
  # before persisting and store the stripped copy — what gets recorded must be
  # what a reader downloads, the same line the image path draws.
  #
  # Unlike the image path this does NOT fall back to the original on failure.
  # A document that cannot be stripped is refused, because the metadata a PDF
  # carries is the identifying kind and storing it unstripped is the outcome
  # #807 exists to prevent.
  #
  # Matched on `ext: ".pdf"` specifically, not `kind: :document` generally
  # (#808): `DocumentProcessor.strip_metadata/1` shells out to qpdf, which
  # cannot open a zip or an OLE2 file at all — trying would refuse every
  # office/zip upload with `:strip_failed`. Every other document extension
  # falls through to the plain `store_and_create/5` clause below, same as a
  # caption track. See the moduledoc's "Office formats are not stripped
  # (yet)" section.
  #
  # `stripped` is `DocumentProcessor`'s own server-built temp file, never
  # caller input — the traversal warning is a false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, %{kind: :document, ext: ".pdf", content_type: content_type}, filename, opts) do
    case DocumentProcessor.strip_metadata(path) do
      {:ok, stripped} ->
        try do
          store_and_create(stripped, ".pdf", content_type, filename, opts)
        after
          File.rm(stripped)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A/V is stripped too (#820), via an ffmpeg stream copy — no re-encode, so it
  # is cheap enough to run on every upload. An MP4 off a phone carries GPS
  # coordinates, the device model and OS version, and often a local wall-clock
  # creation date: the same privacy story as #215's EXIF strip, on the file type
  # where the recording is most likely to be personal.
  #
  # ffmpeg is an OPTIONAL dependency here, so this cannot be an unconditional
  # guarantee. What an operator gets is therefore stated exactly:
  #
  #   * ffmpeg present — stripped, always.
  #   * ffmpeg absent — stored as it arrived, and logged at :warning so the gap
  #     is visible rather than assumed away.
  #   * `require_av_metadata_strip: true` — REFUSED rather than stored
  #     unstripped, for a deployment that needs the strong guarantee. Off by
  #     default: turning it on without ffmpeg installed breaks A/V upload
  #     entirely, which is not a change to make on someone's behalf.
  #
  # With one exception, which is not gated on that setting: running out of temp
  # disk is REFUSED whatever it is set to (#1100). Every other failure above is
  # a standing property of the host or the file — ffmpeg is absent, or this
  # container will never remux — and storing the upload is the better of two
  # bad answers because the alternative is that it can never be uploaded at
  # all. A full disk is neither: it is transient, retrying works, and it is
  # exactly the condition under which the privacy guarantee would otherwise
  # lapse silently and unobserved. So it fails closed and says to try again.
  #
  # `stripped` is `AVProcessor`'s own generated temp path.
  #
  # **The deferred path (#1122).** With `av_metadata_strip: :deferred` and
  # private storage available, none of the above happens on the LiveView
  # process: the upload is stored **privately** under its final key with the
  # row created `quarantined: true`, and `KilnCMS.Media.AVStripWorker` strips,
  # promotes the stripped copy to the public key, releases the quarantine and
  # only then enqueues derivation. Until then the row is invisible to every
  # non-editor read (policy), a 404 on `/media/:id/download|stream`, and its
  # `url` points at nothing. What the sync path bounds at two minutes and ~2x
  # the file on `System.tmp_dir!()`, the deferred path moves off the request
  # entirely — but it needs somewhere to hold the unstripped original that no
  # delivery route serves from, and that is what `Storage.store_private/2` is
  # (#481): a private blob has no `url/1` at all. Without a private store the
  # sync path runs, with a one-time warning: silently degrading to "stored
  # public and unstripped for a while" would be worse than the thing being
  # deferred.
  # sobelow_skip ["Traversal.FileModule"]
  defp persist(path, %{kind: kind, ext: ext, content_type: content_type} = spec, filename, opts)
       when kind in [:video, :audio] do
    if defer_av_strip?() do
      quarantine_av(path, ext, content_type, filename, opts)
    else
      strip_av_now(path, spec, ext, content_type, filename, opts)
    end
  end

  # A caption track is text this codebase already parsed — no container, nothing
  # to strip, and no reason to hand it to ffmpeg.
  defp persist(path, %{ext: ext, content_type: content_type}, filename, opts),
    do: store_and_create(path, ext, content_type, filename, opts)

  # #1122. Stage the upload as it arrived, privately, and hand the strip to the
  # worker. The size cap was checked on the received bytes already; the worker
  # re-checks the stripped copy against the same cap before promoting, exactly
  # as the sync path does. `:strip_deferred` in the create attrs is what keeps
  # `create_item/5` from enqueuing derivation — that is the worker's, after
  # promotion, or `VariantWorker`/`AVWorker` would fetch a public key that has
  # nothing behind it yet.
  defp quarantine_av(path, ext, content_type, filename, opts) do
    key = Storage.generate_key_with_ext(ext)

    case Storage.store_private(key, path) do
      {:ok, ^key} ->
        case create_item(
               key,
               content_type,
               stored_size(path),
               with_ext(filename, ext),
               Keyword.put(opts, :quarantined?, true)
             ) do
          {:ok, item} ->
            max_bytes =
              Keyword.get(opts, :max_bytes) || cap_for(%{kind: MediaKind.of(content_type)})

            enqueue_strip(item, ext, max_bytes)
            {:ok, item}

          {:error, _reason} = error ->
            error
        end

      _ ->
        {:error, :storage_failed}
    end
  end

  # Not `insert_job/2`: a missed derivation costs variants, a missed strip job
  # leaves a quarantined row nobody can serve until `QuarantineReaper` removes
  # it, so the message has to say what an operator should do about it.
  defp enqueue_strip(item, ext, max_bytes) do
    args = %{media_item_id: item.id, org_id: item.org_id, ext: ext, max_bytes: max_bytes}

    case Oban.insert(KilnCMS.Media.AVStripWorker.new(args)) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Media #{item.id} was quarantined but its metadata-strip job was not queued: " <>
            "#{inspect(reason)}. It will not be served; the quarantine reaper removes it " <>
            "after #{KilnCMS.Media.QuarantineReaper.max_age_hours()}h — re-upload the file."
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "Media #{item.id} was quarantined but its strip job was not queued: #{inspect(error)}"
      )

      :ok
  end

  @doc """
  Whether A/V uploads are staged to a private quarantine and stripped by
  `KilnCMS.Media.AVStripWorker` (#1122), rather than remuxed inline on the
  upload request.

  `config :kiln_cms, :av_metadata_strip, :deferred` (`KILN_AV_STRIP_MODE`)
  opts in; `:sync` (the default) is #1112's bounded synchronous path. Deferred
  additionally needs `Storage.private_available?/0` — on the S3 adapter that is
  an operator-configured private bucket — and falls back to the sync path,
  with a warning, when it is not.
  """
  @spec defer_av_strip?() :: boolean()
  def defer_av_strip? do
    case Application.get_env(:kiln_cms, :av_metadata_strip, :sync) do
      :deferred ->
        if Storage.private_available?() do
          true
        else
          warn_no_private_storage()
          false
        end

      _sync ->
        false
    end
  end

  # Once per node, not once per upload — the condition is a standing property
  # of the deployment, and an operator who set `:deferred` without a private
  # bucket needs to hear it once, not on every video.
  defp warn_no_private_storage do
    unless :persistent_term.get({__MODULE__, :warned_no_private_storage}, false) do
      :persistent_term.put({__MODULE__, :warned_no_private_storage}, true)

      Logger.warning(
        "av_metadata_strip is :deferred but this deployment has no private storage " <>
          "(KilnCMS.Storage.private_available?/0 is false), so A/V uploads are being " <>
          "stripped synchronously instead. Configure a private bucket to defer the strip."
      )
    end
  end

  # `stripped` is `AVProcessor`'s own generated temp path (see above).
  # sobelow_skip ["Traversal.FileModule"]
  defp strip_av_now(path, spec, ext, content_type, filename, opts) do
    case AVProcessor.strip_metadata(path, ext) do
      {:ok, stripped} ->
        try do
          # The cap was checked against the file as uploaded, but a remux is
          # not size-preserving in the safe direction: a fragmented MP4 comes
          # back non-fragmented with a full `moov` index, which can be larger.
          # Without this, `max_upload_size/0` — advertised in the docs and used
          # as the client-side ceiling — would stop being the ceiling on what
          # actually lands in the bucket.
          #
          # `cap_for/1` takes the classification MAP, not the kind atom — an
          # atom falls through to the catch-all document clause and caps video
          # at 25 MB, which would refuse every video over that on any host
          # where the strip actually runs.
          with :ok <- check_size(stripped, Keyword.get(opts, :max_bytes) || cap_for(spec)) do
            store_and_create(stripped, ext, content_type, filename, opts)
          end
        after
          File.rm(stripped)
        end

      # Not routed through `store_unstripped_av/6`, because there is no
      # unstripped-store branch to reach: this refuses under every setting.
      {:error, :insufficient_space} ->
        Logger.warning(
          "Refused #{filename}: not enough free space in #{System.tmp_dir!()} to strip " <>
            "its metadata. The strip writes a second full copy of the upload there while " <>
            "the original is still on disk, so peak usage is about twice the file. " <>
            "Free space up, or point TMPDIR at a larger filesystem."
        )

        {:error, :av_strip_no_space}

      {:error, reason} ->
        store_unstripped_av(path, ext, content_type, filename, opts, reason)
    end
  end

  defp store_unstripped_av(path, ext, content_type, filename, opts, reason) do
    if require_av_strip?() do
      Logger.warning("Refused an A/V upload: metadata could not be stripped (#{inspect(reason)})")

      # The two causes need different words in front of an editor: one is
      # "this server can't do it", which retrying will never fix, and the
      # other is "this file couldn't be remuxed", which a re-export might.
      if reason == :unavailable,
        do: {:error, :av_strip_unavailable},
        else: {:error, :strip_failed}
    else
      Logger.warning(
        "Storing #{filename} with its container metadata intact: #{inspect(reason)}. " <>
          remedy_for(reason) <>
          " Set require_av_metadata_strip: true to refuse such uploads instead."
      )

      store_and_create(path, ext, content_type, filename, opts)
    end
  end

  # Naming the wrong remedy is worse than naming none: telling an operator to
  # install ffmpeg on a host that already has it sends them after the one thing
  # that isn't broken.
  defp remedy_for(:unavailable), do: "Install ffmpeg to strip it."

  # A timeout is not "this container can't be remuxed" — the remux was fine and
  # simply did not finish in time, which points at the disk or at a file far
  # bigger than the host can move, not at the codec. Telling an operator their
  # container is unsupported would send them re-exporting a file that is fine.
  defp remedy_for(:timeout),
    do:
      "ffmpeg did not finish remuxing within its wall-clock limit and was stopped; " <>
        "the upload kept its metadata."

  defp remedy_for(_reason),
    do: "ffmpeg is installed but could not remux this container; the upload kept its metadata."

  defp require_av_strip?,
    do: Application.get_env(:kiln_cms, :require_av_metadata_strip, false) == true

  defp store_and_create(source, ext, content_type, filename, opts) do
    key = Storage.generate_key_with_ext(ext)

    case Storage.store(key, source) do
      {:ok, ^key} ->
        create_item(key, content_type, stored_size(source), with_ext(filename, ext), opts)

      _ ->
        {:error, :storage_failed}
    end
  end

  # A caller often has a name but no suffix — a download whose URL is a bare
  # path, or an Unsplash temp file. The suffix that gets appended is the
  # SNIFFED one, so the library never shows a name that contradicts the bytes.
  defp with_ext(filename, ext) do
    if Path.extname(filename) == "", do: filename <> ext, else: filename
  end

  defp create_item(key, content_type, byte_size, filename, opts) do
    attrs =
      %{
        filename: filename,
        content_type: content_type,
        byte_size: byte_size,
        storage_key: key,
        url: Storage.url(key)
      }
      |> put_present(:alt, opts[:alt])
      |> put_present(:caption, opts[:caption])
      |> put_quarantined(Keyword.get(opts, :quarantined?, false))

    case CMS.create_media_item(attrs, Keyword.take(opts, [:actor, :tenant])) do
      {:ok, %{quarantined: true} = item} ->
        # Derivation is the strip worker's to enqueue, after promotion (#1122).
        {:ok, item}

      {:ok, item} ->
        enqueue_processing(item)
        {:ok, item}

      {:error, reason} ->
        # Reclaim the blob: the row is what makes it reachable, so without this
        # a refused create leaves bytes nothing will ever reference or delete.
        # A quarantined upload's blob is in the private store.
        if Keyword.get(opts, :quarantined?, false),
          do: Storage.delete_private(key),
          else: Storage.delete(key)

        # `:create_failed`, not the raw Ash error. `MediaLive` maps this atom to
        # a localized "couldn't be saved" — handing it the struct instead sent
        # it to the catch-all, which tells an editor their file was "not a
        # supported file" when it was refused by policy or a validation.
        Logger.warning("Media item create refused: #{inspect(reason)}")
        {:error, :create_failed}
    end
  end

  defp put_quarantined(attrs, true), do: Map.put(attrs, :quarantined, true)
  defp put_quarantined(attrs, false), do: attrs

  # The stored blob's real size, for `MediaItem.byte_size` — which for an image
  # is the *stripped* copy rather than what arrived.
  # sobelow_skip ["Traversal.FileModule"]
  defp stored_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  # {temp_path, true} when a metadata-stripped copy was produced (caller cleans
  # it up); {original_path, false} when stripping wasn't possible.
  defp stripped_source(path, ext) do
    case ImageProcessor.strip_metadata(path, ext) do
      {:ok, tmp} -> {tmp, true}
      {:error, _} -> {path, false}
    end
  end

  # ── Fetch ──────────────────────────────────────────────────────────────────

  defp safe_url(url) do
    case SafeUrl.validate(url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_url, reason}}
    end
  end

  # `SafeFetch`, not a bare `Req.get`. Validating a hostname and then handing
  # that *hostname* to an HTTP client re-resolves it at connect time, which is a
  # DNS-rebinding hole: an attacker controlling the name answers with a public
  # address during validation and `169.254.169.254` a millisecond later. This is
  # the most content-chosen fetch in the system — the URLs come out of a WXR
  # file someone uploaded — so it uses the module that resolves once, checks,
  # and connects to the literal address with SNI pointed back at the real name.
  # `SafeFetch` also refuses redirects by default (a followed redirect is a
  # fresh resolution the pin never sees) and enforces `:max_bytes` itself.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp download(url) do
    case SafeFetch.get(url, max_bytes: @max_download_size, receive_timeout: @download_timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        write_temp(body)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_temp(body) do
    path = Path.join(System.tmp_dir!(), "kiln-ingest-#{Ecto.UUID.generate()}")

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  # WordPress attachment URLs end in the original filename, which is worth
  # keeping — it is what an editor will search the library by. A URL with no
  # usable last segment falls back to a generated name rather than an empty one.
  defp filename_from_url(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> Path.basename()
    |> URI.decode()
    |> case do
      "" -> "imported-#{Ecto.UUID.generate()}"
      "/" -> "imported-#{Ecto.UUID.generate()}"
      name -> name
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
