defmodule KilnCMS.Media.DirectUpload do
  @moduledoc """
  Two-step uploads straight to object storage, for files too large to send
  through this app comfortably (a 400 MB video past a proxy's request cap).

      1. POST /api/media/uploads            {filename, byte_size}
         → {upload_url, headers, token}
      2. PUT  <upload_url>                   (the client, to the bucket)
      3. POST /api/media/uploads/complete    {token, alt, …}
         → the created media item

  ## The bytes still go through the pipeline

  A presigned upload is only a different way for the bytes to *arrive*. They
  land in **private** storage under a staging key, and completion copies them
  down to a temp file (`Storage.copy_to_file/3`, 8 MB at a time) and hands
  that file to `KilnCMS.Media.Ingest` exactly as `POST /api/media` does —
  byte-sniffing, the per-kind caps, the EXIF/PDF/A-V metadata strip (and its
  #1122 quarantine), variants, and the `MediaItem` create under the caller's
  actor. The staged object is then deleted, whatever the outcome. Nothing a
  client uploads this way is ever served from where it was uploaded to.

  That is also why the flow needs **private** storage, and is unavailable
  (`available?/0` false) without it: the staged object is an unsniffed,
  unstripped upload, and the public bucket is world-readable by design (see
  `KilnCMS.Storage.S3`'s "Public access"). So it runs on the S3 adapter with
  `:private_bucket` configured, and nowhere else — the Local adapter has no
  URL that isn't this app, which is what `POST /api/media` already is.

  ## What bounds it

    * **Size** — the declared `byte_size` is checked against
      `Ingest.max_upload_size/0` before a URL is issued, and is *signed into*
      the URL as `content-length`, so the store refuses any other length.
      Completion re-reads the staged size anyway, and `Ingest` re-applies the
      tighter per-kind cap once it knows the kind.
    * **Who** — the token binds the staging key to the actor and organization
      that asked for it. A token presented by anyone else, or on another
      site, is refused, and completion re-runs the create policy as the
      presenting actor.
    * **Time** — the upload URL lives `url_ttl/0` seconds, the token
      `token_ttl/0`. `KilnCMS.Media.StagedUploadCleanup` is queued at step 1 to
      delete the staging key once the token has expired, so an upload that is
      never completed does not sit in the private bucket forever. If that job
      can't be queued, step 1 fails: a token without one could be neither
      completed nor cleaned up.
    * **Use** — completion first claims that cleanup job
      (`KilnCMS.Media.StagedUploadClaim`, #2724), and holds the claim, renewed
      by a heartbeat, until it has finished. While it is held the job is not
      due, so the delete can't run mid-copy, however long the copy, the
      metadata strip and the variants take. A claim that is lost all the same
      (the heartbeat stalled past the lease) aborts the completion with
      `:claim_lost` rather than ingesting a truncated copy.

  ## Single use

  The claimed job row is the token's record. Only one completion can claim
  it, so a concurrent second completion is refused with `:not_uploaded`. A
  completion that found the staged object deletes it and leaves the claim in
  place, so the token is spent even if that delete failed (the job, now due,
  retries it). A completion that found nothing (it came before the client's
  `PUT`) gives the claim back, so the token can still be completed. Once the
  job has run, nothing is left to claim, and the token is spent.

  ## A site's own store (#1559)

  A site with its own object storage stages into *its* private bucket, with a
  URL signed by *its* key — the operator's credentials never sign a URL for a
  site's store. The token records which store it staged into (`profile_id`), so
  completion and the cleanup job read and delete the staged object there even
  if the site's setting changed in between. The ingest that follows asks the
  site's setting afresh, like any upload.
  """

  alias KilnCMS.Media.{Ingest, StagedUploadClaim, StagedUploadCleanup, Upload}
  alias KilnCMS.Repo
  alias KilnCMS.Storage

  @salt "media direct upload"
  @url_ttl 900
  @token_ttl 3_600
  @staging_prefix "direct-uploads/"

  @doc """
  Whether this deployment can offer direct uploads (see the moduledoc) — for the
  site `org_id`, whose own store (#1559) may differ from the deployment's.
  """
  @spec available?(Ash.UUID.t() | nil) :: boolean()
  def available?(org_id \\ nil) do
    case Storage.upload_target(org_id) do
      {:ok, site} -> Storage.direct_uploads_available?(site)
      {:error, _reason} -> false
    end
  end

  @doc "Seconds an issued upload URL stays valid."
  @spec url_ttl() :: pos_integer()
  def url_ttl, do: @url_ttl

  @doc "Seconds a token may be completed within."
  @spec token_ttl() :: pos_integer()
  def token_ttl, do: @token_ttl

  @doc """
  Issue an upload URL for one file. `params` carries `"filename"` and
  `"byte_size"`. The caller has already been through `Upload.authorize/2`.

  Returns `{:ok, %{token, upload_url, method, headers, expires_at, max_bytes}}`,
  `{:error, :direct_uploads_unavailable}`, `{:error, :too_large}`,
  `{:error, {:invalid, field, message}}`, or `{:error, :storage_failed}` when
  the staging cleanup could not be queued.
  """
  @spec begin(map(), term(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def begin(params, actor, org_id) do
    with {:ok, site} <- Storage.upload_target(org_id),
         :ok <- check_available(site),
         {:ok, filename} <- filename(params),
         {:ok, byte_size} <- declared_size(params),
         key = @staging_prefix <> Ecto.UUID.generate(),
         {:ok, %{url: url, headers: headers}} <-
           Storage.presign_private_put(key, byte_size, @url_ttl, site),
         :ok <- schedule_cleanup(key, org_id, site) do
      token =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{
          key: key,
          filename: filename,
          byte_size: byte_size,
          actor_id: actor.id,
          org_id: org_id,
          profile_id: Storage.profile_id(site)
        })

      {:ok,
       %{
         token: token,
         upload_url: url,
         method: "PUT",
         headers: headers,
         expires_at: DateTime.utc_now() |> DateTime.add(@url_ttl) |> DateTime.truncate(:second),
         max_bytes: Ingest.max_upload_size()
       }}
    end
  end

  @doc """
  Ingest the object a `begin/3` token staged, as `actor` on `org_id`, with
  `metadata` from `Upload.metadata/1`. A staged object that was found is
  deleted however this ends.

  Errors: `{:error, :invalid_token}` (bad, expired, or someone else's),
  `{:error, :not_uploaded}` (nothing at the staging key — never PUT, already
  completed, being completed right now, or cleaned up),
  `{:error, :size_mismatch}`, `{:error, :claim_lost}` (the cleanup job's
  claim lapsed mid-completion; see "Single use"), or anything
  `Ingest.store_file/3` returns.

  Never call it inside a `Repo.transaction`: the claim's row lock would be
  held until that transaction commits, and the claim's heartbeat renews it
  from another connection, so it would wait on that lock throughout (see
  `KilnCMS.Media.StagedUploadClaim`, "Not inside a transaction"). It raises
  `ArgumentError` if it is.
  """
  @spec complete(String.t(), Upload.metadata(), term(), String.t() | nil) ::
          {:ok, struct()} | {:error, term()}
  def complete(token, metadata, actor, org_id) when is_binary(token) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "DirectUpload.complete/4 must not run inside a transaction: " <>
              "its claim's heartbeat would wait on the claim's own row lock"
    end

    with {:ok, claims} <- verify(token, actor, org_id),
         {:ok, claim} <- StagedUploadClaim.claim(claims.key) do
      heartbeat = StagedUploadClaim.start_heartbeat(claim)

      # On a raise the heartbeat still stops. One before the object was found
      # gives the claim back (`find_staged/4`); one after leaves it to lapse,
      # and the cleanup job deletes the object when it does.
      {consumed?, result} =
        try do
          consume(claims, claim, heartbeat, metadata, actor, org_id)
        after
          StagedUploadClaim.stop_heartbeat(heartbeat)
        end

      :ok = StagedUploadClaim.settle(claim, consumed?)
      or_claim_lost(result, heartbeat)
    end
  end

  def complete(_token, _metadata, _actor, _org_id), do: {:error, :invalid_token}

  defp check_available(site) do
    if Storage.direct_uploads_available?(site),
      do: :ok,
      else: {:error, :direct_uploads_unavailable}
  end

  # The store the token staged into — the operator's (`nil`) or a site profile,
  # read tenant-scoped to the token's own site. A token from before #1559 has
  # no `profile_id` and staged into the operator's store.
  defp staged_store(claims, org_id) do
    case Map.get(claims, :profile_id) do
      nil ->
        if Storage.direct_uploads_available?(nil),
          do: {:ok, nil},
          else: {:error, :direct_uploads_unavailable}

      profile_id ->
        Storage.locate(%{storage_profile_id: profile_id, org_id: org_id})
    end
  end

  # One refusal for every way a token can be wrong, so a caller holding
  # someone else's token learns nothing about whose it was.
  defp verify(token, actor, org_id) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @token_ttl) do
      {:ok, %{actor_id: actor_id, org_id: ^org_id} = claims}
      when not is_nil(actor) and actor_id == actor.id ->
        {:ok, claims}

      _other ->
        {:error, :invalid_token}
    end
  end

  # `{consumed?, result}`: consumed once a staged object was found, which is
  # also when it is deleted, whatever the ingest's outcome.
  defp consume(claims, claim, heartbeat, metadata, actor, org_id) do
    case find_staged(claims, claim, heartbeat, org_id) do
      {:ok, staged, size} ->
        try do
          {true, ingest_staged(claims, staged, size, claim, metadata, actor, org_id)}
        after
          Storage.delete_private(claims.key, staged)
        end

      error ->
        {false, error}
    end
  end

  # Not a boundary that handles the raise: it re-raises. Nothing has been
  # consumed yet, so the claim is given back first rather than left to lapse,
  # which would spend a token whose object is still there to complete.
  defp find_staged(claims, claim, heartbeat, org_id) do
    with {:ok, staged} <- staged_store(claims, org_id),
         {:ok, size} <- staged_size(claims.key, staged) do
      {:ok, staged, size}
    end
  rescue
    exception ->
      StagedUploadClaim.stop_heartbeat(heartbeat)
      :ok = StagedUploadClaim.settle(claim, false)
      reraise exception, __STACKTRACE__
  end

  # The staged size is re-read rather than trusted from the token: the signed
  # `content-length` should make them equal, but "should" is the object
  # store's promise, and the check is one ranged read. A claim lost during the
  # copy means the cleanup job may have deleted the object under it, so the
  # copy is not ingested.
  defp ingest_staged(claims, staged, size, claim, metadata, actor, org_id) do
    tmp = Path.join(System.tmp_dir!(), "kiln-direct-#{Ecto.UUID.generate()}")

    try do
      with :ok <- same_size(size, claims.byte_size),
           :ok <- Storage.copy_to_file(claims.key, tmp, private?: true, at: staged),
           :ok <- still_claimed(claim) do
        Upload.from_file(tmp, claims.filename, metadata, actor, org_id)
      end
    after
      rm(tmp)
    end
  end

  # Whatever failed, a lost claim is the reason: the object may have been
  # deleted under the copy, and the token is spent.
  defp or_claim_lost({:error, _reason} = error, heartbeat),
    do: if(StagedUploadClaim.lost?(heartbeat), do: {:error, :claim_lost}, else: error)

  defp or_claim_lost(ok, _heartbeat), do: ok

  # Asked of the database rather than the heartbeat's flag, which is only as
  # fresh as its last beat: the copy must not be ingested unless the claim
  # holds now. A renewal that could not be made counts as lost too.
  defp still_claimed(claim) do
    case StagedUploadClaim.renew(claim) do
      :ok -> :ok
      _lost_or_failed -> {:error, :claim_lost}
    end
  end

  defp schedule_cleanup(key, org_id, site) do
    case StagedUploadCleanup.schedule(key, @token_ttl + 60, org_id, Storage.profile_id(site)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :storage_failed}
    end
  end

  defp staged_size(key, staged) do
    case Storage.fetch_private_range(key, 0, 0, staged) do
      {:ok, %{total: total}} -> {:ok, total}
      {:error, _reason} -> {:error, :not_uploaded}
    end
  end

  defp same_size(size, size), do: :ok
  defp same_size(_actual, _declared), do: {:error, :size_mismatch}

  # `tmp` is built above from System.tmp_dir! + a UUID, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm(path), do: File.rm(path)

  defp filename(params), do: Upload.filename(params["filename"])

  defp declared_size(%{"byte_size" => size}) when is_integer(size) and size > 0 do
    if size <= Ingest.max_upload_size(), do: {:ok, size}, else: {:error, :too_large}
  end

  # A form-encoded body carries it as a string.
  defp declared_size(%{"byte_size" => size} = params) when is_binary(size) do
    case Integer.parse(size) do
      {int, ""} -> declared_size(%{params | "byte_size" => int})
      _ -> declared_size(%{})
    end
  end

  defp declared_size(_params), do: {:error, {:invalid, "byte_size", "must be a positive integer"}}
end
