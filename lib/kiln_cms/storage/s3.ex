defmodule KilnCMS.Storage.S3 do
  @moduledoc """
  S3-compatible `KilnCMS.Storage` adapter (AWS S3, MinIO, R2, …).

  Select it in production with:

      config :kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.S3

      config :kiln_cms, KilnCMS.Storage.S3,
        bucket: "my-bucket",
        # Public base URL objects are served from — a CDN, the bucket's website
        # endpoint, or e.g. "http://localhost:9000/my-bucket" for MinIO. The key
        # is appended to this, so it must already include the bucket path.
        public_base_url: "https://cdn.example.com"

  Credentials, region and the endpoint host come from the standard `ex_aws`
  configuration — see `config/runtime.exs`. Path-style addressing (ExAws's
  default) is used, which every S3-compatible provider supports. HTTP transport
  goes through `KilnCMS.Storage.S3.ReqClient` (Req, not hackney).

  ## Providers

  Any S3-compatible store works by pointing `ex_aws`'s `:s3` config at its
  endpoint (`S3_ENDPOINT_HOST` etc. in `config/runtime.exs`):

    * **AWS S3** — no endpoint host needed; set the region.
    * **Cloudflare R2** — host `<account>.r2.cloudflarestorage.com`, region `auto`.
    * **Backblaze B2** — host `s3.<region>.backblazeb2.com`.
    * **Wasabi** — host `s3.<region>.wasabisys.com`.
    * **MinIO** — your own host/port (dev: `localhost:9000`, scheme `http://`).

  ## Public access

  No object ACL is sent by default. Public read is configured at the *bucket*
  level — which is how R2, B2, Wasabi and modern AWS (buckets with "Bucket owner
  enforced" reject per-object ACLs) all expect it — and `url/1` points at the
  bucket's public base / CDN. If your bucket instead relies on per-object canned
  ACLs, set `config :kiln_cms, KilnCMS.Storage.S3, acl: :public_read` (or
  `S3_ACL=public_read`).

  ## Caching

  Every object is uploaded with `Cache-Control: public, max-age=31536000,
  immutable`, so a CDN in front of the bucket (and the browser) can cache it
  indefinitely without revalidating. This is safe because storage keys are
  UUIDs written once: edits and variant regeneration always mint a *new* key
  rather than overwrite an existing one, so a blob never changes under its URL.
  The `Plug.Static` mount serving the Local adapter uses the same value. See
  `docs/media-pipeline.md` for the CDN deployment guide.

  ## Security headers

  Objects are also uploaded with `Content-Disposition: attachment`, matching
  what `KilnCMSWeb.Endpoint` puts on every `/uploads/*` response for the Local
  adapter — defense-in-depth against a stored file being interpreted as active
  content. Disposition is ignored for `<img>`/subresource loads, and every
  media URL Kiln emits is a subresource, so images render normally; it only
  takes effect when someone navigates straight at the URL.

  Two things differ from the Local adapter and are worth knowing before you
  deploy:

    * It is **object metadata written at `PUT` time**, not a per-request header.
      Changing your mind later means rewriting the existing objects
      (`aws s3 cp --recursive --metadata-directive REPLACE`), not just shipping
      a deploy. `url/1` returns a plain public URL rather than a presigned one,
      so there is no per-request `response-content-disposition` override either.

    * The companion `X-Content-Type-Options: nosniff` **cannot** be carried
      here — S3 stores a fixed set of system headers (`Content-Type`,
      `Content-Disposition`, `Cache-Control`, …) and anything else comes back
      prefixed as `x-amz-meta-*`. Serve it from the CDN or bucket instead; see
      the "Production storage & CDN" section of `docs/media-pipeline.md`.

  ## Private storage (#481)

  Gated documents need a bucket the app can read but the public can't — this
  adapter's public `bucket` doesn't qualify, since "public read is
  bucket-level" (above) means every object in it is reachable at
  `public_base_url/<key>` regardless of what this app ever links to.
  `store_private/2`/`fetch_private/1`/`delete_private/1` operate against a
  **separate, operator-configured** bucket instead:

      config :kiln_cms, KilnCMS.Storage.S3, private_bucket: "my-private-bucket"

  That bucket needs no public-read config, no CDN, and no `public_base_url` —
  this app is the only reader, authenticated with the same `ex_aws`
  credentials as the public bucket, fetching object bytes server-side
  (`ExAws.S3.get_object/2`) and streaming them through
  `KilnCMSWeb.MediaDownloadController` rather than ever handing out a direct
  URL. Without `:private_bucket` configured, `private_available?/0` is
  `false` and gating a document is refused rather than silently falling back
  to the public bucket.
  """
  @behaviour KilnCMS.Storage

  # Keys are write-once UUIDs (see "Caching" above), so responses never need
  # revalidation. Mirrors the /uploads Plug.Static config in KilnCMSWeb.Endpoint.
  @cache_control "public, max-age=31536000, immutable"

  # Mirrors the `content-disposition: attachment` that KilnCMSWeb.Endpoint's
  # secure_upload_headers/2 puts on the Local adapter's responses, so swapping
  # adapters doesn't silently drop the control. See "Security headers" above.
  @content_disposition "attachment"

  @impl true
  # source_path is a server-side upload temp file (from MediaLive), not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def store(key, source_path), do: put(bucket(), key, source_path, upload_opts(key))

  @impl true
  def fetch(key) do
    case bucket() |> ExAws.S3.get_object(key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    # S3 deletes are idempotent — a missing object still returns 2xx.
    case bucket() |> ExAws.S3.delete_object(key) |> ExAws.request() do
      {:ok, _resp} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key), do: "#{public_base_url()}/#{key}"

  @impl true
  # source_path is a server-side upload temp file, not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def store_private(key, source_path) do
    with {:ok, bucket} <- private_bucket(), do: put_private_object(bucket, key, source_path)
  end

  @impl true
  def fetch_private(key) do
    with {:ok, bucket} <- private_bucket() do
      case bucket |> ExAws.S3.get_object(key) |> ExAws.request() do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete_private(key) do
    with {:ok, bucket} <- private_bucket() do
      case bucket |> ExAws.S3.delete_object(key) |> ExAws.request() do
        {:ok, _resp} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def private_available?, do: match?({:ok, _bucket}, private_bucket())

  @impl true
  def fetch_range(key, first, last), do: get_range(bucket(), key, first, last)

  @impl true
  def fetch_private_range(key, first, last) do
    with {:ok, bucket} <- private_bucket(), do: get_range(bucket, key, first, last)
  end

  # S3 answers a ranged GET with `206` and a `Content-Range: bytes a-b/total`
  # header, which is where the authoritative total size comes from — cheaper
  # and more truthful than a separate HEAD. It also clamps an over-long `last`
  # to the end of the object itself, so the response header (not the request)
  # is what defines the range actually served.
  defp get_range(bucket, key, first, last) do
    case bucket
         |> ExAws.S3.get_object(key, range: range_header(first, last))
         |> ExAws.request() do
      {:ok, %{body: body, headers: headers}} ->
        parse_content_range(headers, body, first)

      # S3 returns 416 for a range starting past the end of the object.
      {:error, {:http_error, 416, _resp}} ->
        {:error, :range_not_satisfiable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp range_header(first, :eof), do: "bytes=#{first}-"
  defp range_header(first, last), do: "bytes=#{first}-#{last}"

  defp parse_content_range(headers, body, requested_first) do
    with value when is_binary(value) <- header(headers, "content-range"),
         [_all, first, last, total] <-
           Regex.run(~r/bytes\s+(\d+)-(\d+)\/(\d+)/, value) do
      {:ok,
       %{
         bytes: body,
         first: String.to_integer(first),
         last: String.to_integer(last),
         total: String.to_integer(total)
       }}
    else
      # A provider that answered 200 with the whole object rather than 206 (or
      # sent no parseable Content-Range) leaves us unable to state a truthful
      # Content-Range, and guessing one is worse than not serving a partial
      # response at all — the caller falls back to a plain 200.
      _ -> {:error, {:no_content_range, requested_first}}
    end
  end

  # ExAws returns headers as a list of {name, value}; casing is provider-
  # dependent, so match case-insensitively.
  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(to_string(key)) == name, do: value
      _ -> nil
    end)
  end

  defp header(_headers, _name), do: nil

  # Shared by the streamed `store/2` and the buffered private path — the same
  # object metadata either way (see "Caching" and "Security headers" above).
  defp upload_opts(key) do
    [
      content_type: content_type(key),
      cache_control: @cache_control,
      content_disposition: @content_disposition
    ] ++ acl_opt()
  end

  # No cache-control/content-disposition metadata: a private object is only
  # ever read server-side via `fetch_private/1` and streamed by
  # `MediaDownloadController`, which sets its own response headers per
  # request (including the original filename) — S3 object metadata is never
  # seen by a client here, unlike the public bucket's `url/1` path.
  defp put_private_object(bucket, key, source_path), do: put(bucket, key, source_path, [])

  # Objects above this go up as a streamed multipart upload; everything else
  # takes the single PUT it always has (#494).
  #
  # The split is deliberate, not a shortcut. `ExAws.S3.upload/3` ALWAYS does a
  # real multipart — initiate, part, complete — so routing every object
  # through it would turn each 4 KB thumbnail variant into three round trips.
  # And a single PUT is fine right up until it isn't: `File.read` puts the
  # whole object on the heap, which was unremarkable at the old 25 MB document
  # ceiling and is not at the 500 MB video one (S3 also refuses a single PUT
  # above 5 GB outright).
  @multipart_threshold 16 * 1024 * 1024

  # sobelow_skip ["Traversal.FileModule"]
  defp put(bucket, key, source_path, opts) do
    case File.stat(source_path) do
      {:ok, %{size: size}} when size > @multipart_threshold ->
        multipart_put(bucket, key, source_path, opts)

      {:ok, _stat} ->
        single_put(bucket, key, source_path, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp single_put(bucket, key, source_path, opts) do
    with {:ok, body} <- File.read(source_path),
         {:ok, _resp} <- bucket |> ExAws.S3.put_object(key, body, opts) |> ExAws.request() do
      {:ok, key}
    end
  end

  defp multipart_put(bucket, key, source_path, opts) do
    source_path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket, key, opts)
    |> ExAws.request()
    |> case do
      {:ok, _resp} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_type(key), do: MIME.from_path(key)

  # Only send an x-amz-acl header when one is configured; the default (none)
  # works across R2/B2/Wasabi and modern AWS, which expect bucket-level access.
  defp acl_opt do
    case Keyword.get(config(), :acl) do
      nil -> []
      acl -> [acl: acl]
    end
  end

  defp bucket do
    case Keyword.get(config(), :bucket) do
      nil ->
        raise "KilnCMS.Storage.S3 requires a :bucket; set config :kiln_cms, KilnCMS.Storage.S3, bucket: ..."

      bucket ->
        bucket
    end
  end

  defp public_base_url do
    case Keyword.get(config(), :public_base_url) do
      nil ->
        raise "KilnCMS.Storage.S3 requires a :public_base_url; set config :kiln_cms, KilnCMS.Storage.S3, public_base_url: ..."

      url ->
        String.trim_trailing(url, "/")
    end
  end

  defp private_bucket do
    case Keyword.get(config(), :private_bucket) do
      nil -> {:error, :private_storage_not_configured}
      bucket -> {:ok, bucket}
    end
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
