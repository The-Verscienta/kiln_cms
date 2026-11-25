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
      the "Production storage and CDN" section of `docs/media-pipeline.md`.

  ## Large objects and slow uplinks (#494, #2725)

  An object over 16 MiB goes up as a multipart upload in 5 MiB parts, four at
  a time. Each part has as long as it takes at a minimum throughput, never
  less than 30 seconds, and a part that runs out of time or meets a server
  error is sent again, up to three attempts in all, before the upload is
  aborted. The defaults suit an uplink of about 1 Mbit/s or more; a slower
  one can lower the floor:

      config :kiln_cms, KilnCMS.Storage.S3,
        # Per part, and four parts share the uplink. S3_UPLOAD_MIN_BYTES_PER_SECOND.
        part_min_bytes_per_second: 32_768,
        part_min_timeout_ms: 30_000,
        part_attempts: 3,
        # Doubled before each further attempt.
        part_retry_backoff_ms: 1_000

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

  ## A site's own bucket (#1559)

  Every operation also comes in an arity that takes a `KilnCMS.Storage.Profile`
  last: a site's own bucket, with its own buckets, public base URL and a
  complete ExAws config built from the site's settings alone
  (`KilnCMS.Storage.SiteProfiles`). Those calls never touch the `ex_aws`
  application config — not its credentials, session token, endpoint or region
  — and send no `:acl`. `KilnCMS.Storage` routes to them whenever an item or
  an upload belongs to a site's store, whatever adapter the operator runs.
  """
  @behaviour KilnCMS.Storage

  require Logger

  # Keys are write-once UUIDs (see "Caching" above), so responses never need
  # revalidation. Mirrors the /uploads Plug.Static config in KilnCMSWeb.Endpoint.
  @cache_control "public, max-age=31536000, immutable"

  # Mirrors the `content-disposition: attachment` that KilnCMSWeb.Endpoint's
  # secure_upload_headers/2 puts on the Local adapter's responses, so swapping
  # adapters doesn't silently drop the control. See "Security headers" above.
  @content_disposition "attachment"

  # ## A site's own store (#1559)
  #
  # Every operation below takes a `site` last: `nil` for the operator's store
  # (the `config :kiln_cms, KilnCMS.Storage.S3` buckets, and ExAws's
  # application config — `ExAws.request/1`, exactly as before), or a
  # `KilnCMS.Storage.Profile` for a site's, whose buckets and complete ExAws
  # config come from the site's profile alone and go to
  # `ExAws.Operation.perform/2` with nothing merged underneath. See
  # `KilnCMS.Storage.SiteProfiles`'s moduledoc for why the merge is the danger.
  # `KilnCMS.Storage` calls the arity-with-profile functions directly for a
  # site's store, whatever the operator's adapter is.

  alias KilnCMS.Storage.Profile

  @impl true
  # source_path is a server-side upload temp file (from MediaLive), not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def store(key, source_path), do: store(key, source_path, nil)

  @doc "`store/2` against a site's store (`nil` is the operator's)."
  @spec store(String.t(), String.t(), Profile.t() | nil) :: {:ok, String.t()} | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def store(key, source_path, site),
    do: put(bucket(site), key, source_path, upload_opts(key, site), site)

  @impl true
  def fetch(key), do: fetch(key, nil)

  @doc "`fetch/1` against a site's store."
  @spec fetch(String.t(), Profile.t() | nil) :: {:ok, binary()} | {:error, term()}
  def fetch(key, site), do: get(bucket(site), key, site)

  @impl true
  def delete(key), do: delete(key, nil)

  @doc "`delete/1` against a site's store."
  @spec delete(String.t(), Profile.t() | nil) :: :ok | {:error, term()}
  def delete(key, site), do: delete_object(bucket(site), key, site)

  @impl true
  def url(key), do: url(key, nil)

  @doc "`url/1` for a site's store: its public base URL."
  @spec url(String.t(), Profile.t() | nil) :: String.t()
  def url(key, site), do: "#{public_base_url(site)}/#{key}"

  @impl true
  # source_path is a server-side upload temp file, not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def store_private(key, source_path), do: store_private(key, source_path, nil)

  @doc "`store_private/2` against a site's private bucket."
  @spec store_private(String.t(), String.t(), Profile.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def store_private(key, source_path, site) do
    with {:ok, bucket} <- private_bucket(site),
         do: put_private_object(bucket, key, source_path, site)
  end

  @impl true
  def fetch_private(key), do: fetch_private(key, nil)

  @doc "`fetch_private/1` against a site's private bucket."
  @spec fetch_private(String.t(), Profile.t() | nil) :: {:ok, binary()} | {:error, term()}
  def fetch_private(key, site) do
    with {:ok, bucket} <- private_bucket(site), do: get(bucket, key, site)
  end

  @impl true
  def delete_private(key), do: delete_private(key, nil)

  @doc "`delete_private/1` against a site's private bucket."
  @spec delete_private(String.t(), Profile.t() | nil) :: :ok | {:error, term()}
  def delete_private(key, site) do
    with {:ok, bucket} <- private_bucket(site), do: delete_object(bucket, key, site)
  end

  @impl true
  def private_available?, do: private_available?(nil)

  @doc "Whether a site's store has a private bucket."
  @spec private_available?(Profile.t() | nil) :: boolean()
  def private_available?(site), do: match?({:ok, _bucket}, private_bucket(site))

  # The direct-upload API's first leg. A presigned PUT rather than a presigned
  # POST policy: POST Object is an AWS-and-MinIO feature that R2 and B2 do not
  # implement, and the one thing a POST policy adds — `content-length-range` —
  # a signed `content-length` header does too, more strictly: the store
  # refuses any body whose length differs from the one signed. Path-style, like
  # every other request this adapter makes. Private bucket only (see
  # `KilnCMS.Storage.presign_private_put/3` for why).
  @impl true
  def presign_private_put(key, byte_size, expires_in),
    do: presign_private_put(key, byte_size, expires_in, nil)

  @doc "`presign_private_put/3` against a site's private bucket, signed with the site's key."
  @spec presign_private_put(String.t(), pos_integer(), pos_integer(), Profile.t() | nil) ::
          {:ok, %{url: String.t(), headers: %{String.t() => String.t()}}} | {:error, term()}
  def presign_private_put(key, byte_size, expires_in, site) do
    with {:ok, bucket} <- private_bucket(site) do
      headers = %{"content-length" => Integer.to_string(byte_size)}

      site
      |> presign_config()
      |> ExAws.S3.presigned_url(:put, bucket, key,
        expires_in: expires_in,
        headers: Map.to_list(headers)
      )
      |> case do
        {:ok, url} -> {:ok, %{url: url, headers: headers}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def fetch_range(key, first, last), do: fetch_range(key, first, last, nil)

  @doc "`fetch_range/3` against a site's store."
  @spec fetch_range(String.t(), non_neg_integer(), non_neg_integer() | :eof, Profile.t() | nil) ::
          {:ok, KilnCMS.Storage.range_read()} | {:error, term()}
  def fetch_range(key, first, last, site), do: get_range(bucket(site), key, first, last, site)

  @impl true
  def fetch_private_range(key, first, last), do: fetch_private_range(key, first, last, nil)

  @doc "`fetch_private_range/3` against a site's private bucket."
  @spec fetch_private_range(
          String.t(),
          non_neg_integer(),
          non_neg_integer() | :eof,
          Profile.t() | nil
        ) :: {:ok, KilnCMS.Storage.range_read()} | {:error, term()}
  def fetch_private_range(key, first, last, site) do
    with {:ok, bucket} <- private_bucket(site), do: get_range(bucket, key, first, last, site)
  end

  # The one place an operation meets a config. The operator's store keeps
  # `ExAws.request/1` — ExAws's application config, as it always has. A site's
  # gets its own complete config and nothing else (see the note above).
  defp request(op, nil), do: ExAws.request(op)
  defp request(op, %Profile{config: config}), do: ExAws.Operation.perform(op, config)

  defp presign_config(nil), do: ExAws.Config.new(:s3)
  defp presign_config(%Profile{config: config}), do: config

  defp get(bucket, key, site) do
    case bucket |> ExAws.S3.get_object(key) |> request(site) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  # S3 deletes are idempotent — a missing object still returns 2xx.
  defp delete_object(bucket, key, site) do
    case bucket |> ExAws.S3.delete_object(key) |> request(site) do
      {:ok, _resp} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # S3 answers a ranged GET with `206` and a `Content-Range: bytes a-b/total`
  # header, which is where the authoritative total size comes from — cheaper
  # and more truthful than a separate HEAD. It also clamps an over-long `last`
  # to the end of the object itself, so the response header (not the request)
  # is what defines the range actually served.
  defp get_range(bucket, key, first, last, site) do
    case bucket
         |> ExAws.S3.get_object(key, range: range_header(first, last))
         |> request(site) do
      # A provider that ignores `Range` answers 200 with the whole object, and
      # an empty whole object is an empty blob (#3069).
      {:ok, %{status_code: 200, body: ""}} when first == 0 ->
        {:error, {:range_not_satisfiable, 0}}

      {:ok, %{body: body, headers: headers}} ->
        parse_content_range(headers, body, first)

      # A range starting at 0 is unsatisfiable only for an empty object
      # (RFC 9110 §14.1.1), so the total is known: 0 (#3069).
      {:error, {:http_error, 416, _resp} = refusal} when first == 0 ->
        confirm_empty(bucket, key, site, refusal)

      # S3 returns 416 for a range starting past the end of the object.
      {:error, {:http_error, 416, _resp}} ->
        {:error, :range_not_satisfiable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Confirmed with a HEAD rather than taken on the 416's word. Read as "empty",
  # a 416 on an object that has bytes would make `Storage.copy_to_file/3`
  # write an empty file and call it complete, and the A/V strip would promote
  # that over the real upload. So anything but a size of 0 keeps the 416 as
  # an error.
  defp confirm_empty(bucket, key, site, refusal) do
    case bucket |> ExAws.S3.head_object(key) |> request(site) do
      {:ok, %{headers: headers}} ->
        if header(headers, "content-length") == "0",
          do: {:error, {:range_not_satisfiable, 0}},
          else: {:error, refusal}

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
  defp upload_opts(key, site) do
    [
      content_type: content_type(key),
      cache_control: @cache_control,
      content_disposition: @content_disposition
    ] ++ acl_opt(site)
  end

  # No cache-control/content-disposition metadata: a private object is only
  # ever read server-side via `fetch_private/1` and streamed by
  # `MediaDownloadController`, which sets its own response headers per
  # request (including the original filename) — S3 object metadata is never
  # seen by a client here, unlike the public bucket's `url/1` path.
  defp put_private_object(bucket, key, source_path, site),
    do: put(bucket, key, source_path, [], site)

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
  defp put(bucket, key, source_path, opts, site) do
    case File.stat(source_path) do
      {:ok, %{size: size}} when size > @multipart_threshold ->
        multipart_put(bucket, key, source_path, opts, site)

      {:ok, _stat} ->
        single_put(bucket, key, source_path, opts, site)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp single_put(bucket, key, source_path, opts, site) do
    with {:ok, body} <- File.read(source_path),
         {:ok, _resp} <- bucket |> ExAws.S3.put_object(key, body, opts) |> request(site) do
      {:ok, key}
    end
  end

  # The initiate, part and complete steps are driven here rather than through
  # `ExAws.S3.upload/3 |> ExAws.request()`, whose `perform/2` returns a failed
  # part's error without aborting. The parts already sent would then stay on
  # the bucket as an incomplete multipart upload — invisible to a listing, and
  # billed until a lifecycle rule clears them. Holding the `upload_id` lets a
  # failed part or complete send `AbortMultipartUpload` before returning the
  # original error.
  #
  # The steps call `ExAws.S3` operations with `request/2` rather than the
  # `ExAws.S3.Upload` helpers: those pass `ExAws.request/2` a config map where
  # its spec takes a keyword list, and dialyzer then reads them as never
  # returning.
  defp multipart_put(bucket, key, source_path, opts, site) do
    with {:ok, %{body: %{upload_id: upload_id}}} <-
           bucket |> ExAws.S3.initiate_multipart_upload(key, opts) |> request(site) do
      case upload_parts_and_complete(bucket, key, upload_id, source_path, site) do
        {:ok, _resp} ->
          {:ok, key}

        {:error, reason} ->
          abort_multipart(bucket, key, upload_id, site)
          {:error, reason}
      end
    end
  end

  # ## How long a part may take (#2725)
  #
  # A part used to get a fixed 30 s, killed at the deadline. Four 5 MiB parts
  # share the uplink, so under about 5 Mbit/s no part could ever finish and no
  # object over the multipart threshold could be stored at all, however long
  # the caller was prepared to wait.
  #
  # Each attempt at a part now has a deadline that follows its size: the time
  # it takes at `:part_min_bytes_per_second`, and never less than
  # `:part_min_timeout_ms`. A request that goes silent is still cut sooner by
  # `ReqClient`'s receive timeout, and ExAws retries that, a transport error
  # and a `5xx` on its own. The deadline is the backstop for what neither
  # sees: a body send that stops moving, which the socket never times out.
  #
  # A part whose attempt misses its deadline, or comes back with a `5xx` or a
  # transport error once ExAws has given up, is sent again (S3 keeps the last
  # upload of a part number), up to `:part_attempts` in all with a doubling
  # `:part_retry_backoff_ms` between them. Anything else fails the part at
  # once: a `4xx` will not change on a retry.
  @part_concurrency 4
  @default_part_min_bytes_per_second 32 * 1024
  @default_part_min_timeout_ms 30_000
  @default_part_attempts 3
  @default_part_retry_backoff_ms 1_000

  # Every part runs to an answer before the error is taken, so no part is still
  # in flight when the abort goes out (S3 keeps a part that lands after it).
  # No task-level timeout: each part bounds itself, attempt by attempt.
  defp upload_parts_and_complete(bucket, key, upload_id, source_path, site) do
    part = %{bucket: bucket, key: key, upload_id: upload_id, site: site, limits: part_limits()}

    parts =
      source_path
      |> ExAws.S3.Upload.stream_file()
      |> Stream.with_index(1)
      |> Task.async_stream(&upload_part(part, &1),
        max_concurrency: @part_concurrency,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case Enum.find(parts, &match?({:error, _reason}, &1)) do
      nil ->
        bucket
        |> ExAws.S3.complete_multipart_upload(key, upload_id, parts)
        |> request(site)

      error ->
        error
    end
  end

  defp upload_part(part, {chunk, n}) do
    deadline = max(part.limits.min_timeout_ms, div(byte_size(chunk) * 1_000, part.limits.min_bps))
    attempt_part(part, chunk, n, deadline, 1)
  end

  defp attempt_part(part, chunk, n, deadline, attempt) do
    case within(fn -> send_part(part, chunk, n) end, deadline) do
      {:error, reason} when attempt < part.limits.attempts ->
        if retryable_part_error?(reason) do
          Logger.warning(
            "S3 multipart upload #{part.upload_id} for #{part.key}: part #{n} failed " <>
              "(#{inspect(reason)}); retrying, attempt #{attempt + 1} of #{part.limits.attempts}"
          )

          Process.sleep(part.limits.backoff_ms * Integer.pow(2, attempt - 1))
          attempt_part(part, chunk, n, deadline, attempt + 1)
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp send_part(part, chunk, n) do
    case part.bucket
         |> ExAws.S3.upload_part(part.key, part.upload_id, n, chunk)
         |> request(part.site) do
      {:ok, %{headers: headers}} -> {n, header(headers, "etag")}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs `fun` in its own process so a send stuck past `timeout_ms` can be
  # stopped. Killing it closes its connection, so nothing more of the part is
  # sent once the next attempt, or the abort, goes out. (Bytes the kernel had
  # already buffered can still drain; a part that completes that way after the
  # abort is what the bucket's lifecycle rule is the backstop for.)
  defp within(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # What ExAws itself retries, and has retried already by the time it answers:
  # a server error or a request that never got one. Plus our own deadline.
  defp retryable_part_error?(:timeout), do: true
  defp retryable_part_error?({:http_error, status, _body}) when status >= 500, do: true
  defp retryable_part_error?(%Req.TransportError{}), do: true
  defp retryable_part_error?(_reason), do: false

  defp part_limits do
    config = config()

    %{
      min_bps:
        Keyword.get(config, :part_min_bytes_per_second, @default_part_min_bytes_per_second),
      min_timeout_ms: Keyword.get(config, :part_min_timeout_ms, @default_part_min_timeout_ms),
      attempts: Keyword.get(config, :part_attempts, @default_part_attempts),
      backoff_ms: Keyword.get(config, :part_retry_backoff_ms, @default_part_retry_backoff_ms)
    }
  end

  # Best-effort: the store has already failed, and the caller gets that error
  # whether or not the abort lands. A lifecycle rule is the backstop.
  defp abort_multipart(bucket, key, upload_id, site) do
    case bucket |> ExAws.S3.abort_multipart_upload(key, upload_id) |> request(site) do
      {:ok, _resp} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "S3 multipart upload #{upload_id} for #{key} failed and could not be aborted: #{inspect(reason)}"
        )
    end
  end

  defp content_type(key), do: MIME.from_path(key)

  # Only send an x-amz-acl header when one is configured; the default (none)
  # works across R2/B2/Wasabi and modern AWS, which expect bucket-level access.
  # The operator's setting only: a site's bucket is public at the bucket level.
  defp acl_opt(%Profile{}), do: []

  defp acl_opt(nil) do
    case Keyword.get(config(), :acl) do
      nil -> []
      acl -> [acl: acl]
    end
  end

  defp bucket(%Profile{bucket: bucket}), do: bucket

  defp bucket(nil) do
    case Keyword.get(config(), :bucket) do
      nil ->
        raise "KilnCMS.Storage.S3 requires a :bucket; set config :kiln_cms, KilnCMS.Storage.S3, bucket: ..."

      bucket ->
        bucket
    end
  end

  defp public_base_url(%Profile{public_base_url: url}), do: url

  defp public_base_url(nil) do
    case Keyword.get(config(), :public_base_url) do
      nil ->
        raise "KilnCMS.Storage.S3 requires a :public_base_url; set config :kiln_cms, KilnCMS.Storage.S3, public_base_url: ..."

      url ->
        String.trim_trailing(url, "/")
    end
  end

  defp private_bucket(%Profile{private_bucket: nil}),
    do: {:error, :private_storage_not_configured}

  defp private_bucket(%Profile{private_bucket: bucket}), do: {:ok, bucket}

  defp private_bucket(nil) do
    case Keyword.get(config(), :private_bucket) do
      nil -> {:error, :private_storage_not_configured}
      bucket -> {:ok, bucket}
    end
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
