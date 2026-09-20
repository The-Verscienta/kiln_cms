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
      never completed does not sit in the private bucket forever.

  A token is not single-use by any record of its own: completion deletes the
  staged object, and a second completion finds nothing to ingest.
  """

  alias KilnCMS.Media.{Ingest, StagedUploadCleanup, Upload}
  alias KilnCMS.Storage

  @salt "media direct upload"
  @url_ttl 900
  @token_ttl 3_600
  @staging_prefix "direct-uploads/"

  @doc "Whether this deployment can offer direct uploads (see the moduledoc)."
  @spec available?() :: boolean()
  def available?, do: Storage.direct_uploads_available?()

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
  `{:error, :direct_uploads_unavailable}`, `{:error, :too_large}`, or
  `{:error, {:invalid, field, message}}`.
  """
  @spec begin(map(), term(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def begin(params, actor, org_id) do
    with :ok <- check_available(),
         {:ok, filename} <- filename(params),
         {:ok, byte_size} <- declared_size(params),
         key = @staging_prefix <> Ecto.UUID.generate(),
         {:ok, %{url: url, headers: headers}} <-
           Storage.presign_private_put(key, byte_size, @url_ttl) do
      StagedUploadCleanup.schedule(key, @token_ttl + 60)

      token =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, @salt, %{
          key: key,
          filename: filename,
          byte_size: byte_size,
          actor_id: actor.id,
          org_id: org_id
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
  `metadata` from `Upload.metadata/1`. The staged object is deleted however
  this ends.

  Errors: `{:error, :invalid_token}` (bad, expired, or someone else's),
  `{:error, :not_uploaded}` (nothing at the staging key — never PUT, or
  already completed), `{:error, :size_mismatch}`, or anything
  `Ingest.store_file/3` returns.
  """
  @spec complete(String.t(), Upload.metadata(), term(), String.t() | nil) ::
          {:ok, struct()} | {:error, term()}
  def complete(token, metadata, actor, org_id) when is_binary(token) do
    with :ok <- check_available(),
         {:ok, claims} <- verify(token, actor, org_id) do
      try do
        ingest_staged(claims, metadata, actor, org_id)
      after
        Storage.delete_private(claims.key)
      end
    end
  end

  def complete(_token, _metadata, _actor, _org_id), do: {:error, :invalid_token}

  defp check_available do
    if available?(), do: :ok, else: {:error, :direct_uploads_unavailable}
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

  # The staged size is re-read rather than trusted from the token: the signed
  # `content-length` should make them equal, but "should" is the object
  # store's promise, and the check is one ranged read.
  defp ingest_staged(claims, metadata, actor, org_id) do
    tmp = Path.join(System.tmp_dir!(), "kiln-direct-#{Ecto.UUID.generate()}")

    try do
      with {:ok, size} <- staged_size(claims.key),
           :ok <- same_size(size, claims.byte_size),
           :ok <- Storage.copy_to_file(claims.key, tmp, private?: true) do
        Upload.from_file(tmp, claims.filename, metadata, actor, org_id)
      end
    after
      rm(tmp)
    end
  end

  defp staged_size(key) do
    case Storage.fetch_private_range(key, 0, 0) do
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
