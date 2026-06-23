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
  """
  @behaviour KilnCMS.Storage

  @impl true
  # source_path is a server-side upload temp file (from MediaLive), not user input.
  # sobelow_skip ["Traversal.FileModule"]
  def store(key, source_path) do
    with {:ok, body} <- File.read(source_path),
         {:ok, _resp} <- put_object(key, body) do
      {:ok, key}
    else
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp put_object(key, body) do
    opts = [content_type: content_type(key)] ++ acl_opt()

    bucket()
    |> ExAws.S3.put_object(key, body, opts)
    |> ExAws.request()
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

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
