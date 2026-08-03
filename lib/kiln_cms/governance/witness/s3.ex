defmodule KilnCMS.Governance.Witness.S3 do
  @moduledoc """
  S3-compatible witness: one object per checkpoint (#666).

      config :kiln_cms, KilnCMS.Governance.Witness, adapter: KilnCMS.Governance.Witness.S3
      config :kiln_cms, KilnCMS.Governance.Witness.S3,
        bucket: "kiln-governance",
        prefix: "checkpoints/"

  (`KILN_GOVERNANCE_WITNESS=s3`, `KILN_GOVERNANCE_WITNESS_BUCKET`,
  `KILN_GOVERNANCE_WITNESS_PREFIX`.)

  Credentials, region and endpoint come from the same `ex_aws` configuration as
  `KilnCMS.Storage.S3`, so an operator who has already configured media storage
  has configured this. **Use a different bucket.** The media bucket is writable
  by the request path and public-read by design; a witness in it is neither
  tamper-resistant nor private.

  ## Why the conditional write

  `PUT` carries `If-None-Match: *`, so an object that already exists returns
  `412` and the publish reports `{:error, :already_published}` rather than
  replacing it. A sink that accepts an overwrite is worse than no sink: the
  attacker rewrites the published checkpoint to match the doctored database and
  the audit comparison passes. Every S3-compatible store this project documents
  (AWS, R2, B2, MinIO) supports conditional creates; one that does not is not
  usable as a witness, and the 412 is how you find out.

  ## What the bucket still has to do

  The conditional write stops a *rewrite*; it does nothing about a delete. The
  application's credentials must not be able to remove what they wrote, or the
  attacker deletes the object and the checkpoint alongside the anchors. Either:

    * **Object Lock in compliance mode** with a retention period matching your
      audit window — nothing, including the root account, deletes an object
      before it expires; or
    * a bucket policy denying `s3:DeleteObject` and `s3:PutObjectRetention` to
      the principal the application uses, with deletion held by different
      credentials.

  Without one of those this adapter buys distance, not the property.
  """
  @behaviour KilnCMS.Governance.Witness

  alias KilnCMS.Governance.Witness

  @impl true
  def publish(key, body) do
    with {:ok, bucket} <- bucket() do
      bucket
      # `if_none_match` is a first-class `put_object/4` option (ex_aws_s3's
      # `@etag_headers`), so this does not reach into the operation struct for
      # the one header the adapter exists for.
      |> ExAws.S3.put_object(object_key(key), body,
        content_type: "application/json",
        if_none_match: "*"
      )
      |> ExAws.request()
      |> case do
        {:ok, response} ->
          {:ok,
           %{
             "bucket" => bucket,
             "key" => object_key(key),
             "etag" => header(response, "etag"),
             "bytes" => byte_size(body),
             "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower)
           }}

        # 412 is the conditional write refusing to replace an existing object,
        # which is the adapter working. Named rather than passed through as a
        # generic HTTP error so the caller does not retry it forever.
        {:error, {:http_error, 412, _response}} ->
          {:error, :already_published}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def fetch(key) do
    with {:ok, bucket} <- bucket() do
      bucket
      |> ExAws.S3.get_object(object_key(key))
      |> ExAws.request()
      |> case do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, {:http_error, 404, _response}} -> {:error, :not_published}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list(org_id) do
    with {:ok, bucket} <- bucket() do
      bucket
      |> ExAws.S3.list_objects_v2(prefix: object_key("#{org_id}/"))
      # `stream!` pages transparently — an org with years of nightly
      # checkpoints exceeds the 1000-key response limit, and a single
      # `list_objects_v2` would silently report the sink as smaller than it is,
      # which for this audit reads as "no missing rows".
      |> ExAws.stream!()
      |> Enum.map(&String.replace_prefix(&1.key, prefix(), ""))
      |> then(&{:ok, &1})
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def describe do
    case bucket() do
      {:ok, bucket} -> "s3 (#{bucket}/#{prefix()})"
      {:error, _} -> "s3 (unconfigured — set KILN_GOVERNANCE_WITNESS_BUCKET)"
    end
  end

  defp object_key(key), do: prefix() <> key

  defp prefix do
    __MODULE__
    |> Witness.config()
    |> Keyword.get(:prefix, "")
    |> case do
      "" -> ""
      prefix -> String.trim_trailing(prefix, "/") <> "/"
    end
  end

  # An unconfigured bucket is an error value, not a raise: publication runs in a
  # background worker and the audit task walks every org, and neither should die
  # on a misconfiguration it can report.
  defp bucket do
    case Keyword.get(Witness.config(__MODULE__), :bucket) do
      nil -> {:error, :witness_bucket_not_configured}
      bucket -> {:ok, bucket}
    end
  end

  # `Enum.find_value/2` handles a list of pairs and a map identically, so one
  # clause covers both shapes ex_aws has used.
  defp header(%{headers: headers}, name) when is_list(headers) or is_map(headers) do
    Enum.find_value(headers, fn {key, value} -> String.downcase(key) == name && value end)
  end

  defp header(_response, _name), do: nil
end
