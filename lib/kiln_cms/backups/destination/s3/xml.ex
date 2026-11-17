defmodule KilnCMS.Backups.Destination.S3.Xml do
  @moduledoc """
  The few S3 XML answers an S3 destination reads (#2221), parsed defensively:
  the store is an admin-chosen host, so its answers are untrusted input.

  Every body is size-capped and passes `KilnCMS.Xml.check_name_budget/2`
  before `xmerl` sees it (no DTD, no atoms minted past the budget), and every
  value read is a string or an integer: nothing becomes an atom. A body that
  doesn't parse is `{:error, :malformed}`.

  An error's `<Message>` is never read: only its `<Code>`, which
  `KilnCMS.Backups.Destination.S3.Errors` matches against a fixed list.
  """

  import SweetXml, only: [sigil_x: 2]

  @max_bytes 8 * 1024 * 1024
  @max_names 64

  @doc "The root element's name, or `nil` when the body is not XML."
  @spec root(binary()) :: String.t() | nil
  def root(body) do
    case parse(body) do
      {:ok, doc} -> SweetXml.xpath(doc, ~x"name(/*)"s)
      {:error, _reason} -> nil
    end
  end

  @doc "An `<Error>` body's `<Code>`, or `nil`."
  @spec error_code(binary()) :: String.t() | nil
  def error_code(body) do
    with {:ok, doc} <- parse(body),
         "Error" <- SweetXml.xpath(doc, ~x"name(/*)"s),
         code when is_binary(code) and code != "" <- SweetXml.xpath(doc, ~x"/Error/Code/text()"s) do
      String.slice(code, 0, 64)
    else
      _ -> nil
    end
  end

  @doc "`CreateMultipartUpload`'s upload id."
  @spec upload_id(binary()) :: {:ok, String.t()} | {:error, :malformed}
  def upload_id(body) do
    with {:ok, doc} <- parse(body),
         id when is_binary(id) and id != "" <-
           SweetXml.xpath(doc, ~x"/InitiateMultipartUploadResult/UploadId/text()"s) do
      {:ok, id}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc """
  One page of `ListObjectsV2`: its objects (`key`, `size`, `last_modified`
  as the store wrote it) and the continuation token of the next page, `nil`
  on the last.
  """
  @spec list_objects(binary()) ::
          {:ok, [%{key: String.t(), size: integer(), last_modified: String.t()}],
           String.t() | nil}
          | {:error, :malformed}
  def list_objects(body) do
    with {:ok, doc} <- parse(body),
         "ListBucketResult" <- SweetXml.xpath(doc, ~x"name(/*)"s) do
      objects =
        doc
        |> SweetXml.xpath(~x"/ListBucketResult/Contents"l,
          key: ~x"./Key/text()"s,
          size: ~x"./Size/text()"s,
          last_modified: ~x"./LastModified/text()"s
        )
        |> Enum.map(&%{&1 | size: integer(&1.size)})

      {:ok, objects,
       next(
         doc,
         ~x"/ListBucketResult/IsTruncated/text()"s,
         ~x"/ListBucketResult/NextContinuationToken/text()"s
       )}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc """
  One page of `ListParts`: its parts (`number`, `etag` without quotes,
  `size`) and the part-number marker of the next page, `nil` on the last.
  """
  @spec list_parts(binary()) ::
          {:ok, [%{number: integer(), etag: String.t(), size: integer()}], String.t() | nil}
          | {:error, :malformed}
  def list_parts(body) do
    with {:ok, doc} <- parse(body),
         "ListPartsResult" <- SweetXml.xpath(doc, ~x"name(/*)"s) do
      parts =
        doc
        |> SweetXml.xpath(~x"/ListPartsResult/Part"l,
          number: ~x"./PartNumber/text()"s,
          etag: ~x"./ETag/text()"s,
          size: ~x"./Size/text()"s
        )
        |> Enum.map(
          &%{number: integer(&1.number), etag: unquote_etag(&1.etag), size: integer(&1.size)}
        )

      {:ok, parts,
       next(
         doc,
         ~x"/ListPartsResult/IsTruncated/text()"s,
         ~x"/ListPartsResult/NextPartNumberMarker/text()"s
       )}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc "The `CompleteMultipartUpload` request body for `parts` (`{number, etag}`)."
  @spec complete_body([{pos_integer(), String.t()}]) :: binary()
  def complete_body(parts) do
    inner =
      Enum.map(parts, fn {number, etag} ->
        "<Part><PartNumber>#{number}</PartNumber><ETag>" <>
          KilnCMS.Xml.escape(~s("#{etag}")) <> "</ETag></Part>"
      end)

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">),
      inner,
      "</CompleteMultipartUpload>"
    ])
  end

  @doc "An ETag without its quotes (and without a weak-tag `W/`)."
  @spec unquote_etag(String.t() | nil) :: String.t()
  def unquote_etag(nil), do: ""

  def unquote_etag(etag) do
    etag |> String.trim() |> String.replace_prefix("W/", "") |> String.trim("\"")
  end

  defp next(doc, truncated, marker) do
    if SweetXml.xpath(doc, truncated) == "true" do
      case SweetXml.xpath(doc, marker) do
        "" -> nil
        value -> value
      end
    end
  end

  defp integer(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> -1
    end
  end

  defp parse(body)
       when is_binary(body) and byte_size(body) > 0 and byte_size(body) <= @max_bytes do
    with :ok <- KilnCMS.Xml.check_name_budget(body, @max_names) do
      {:ok, SweetXml.parse(body, dtd: :none, quiet: true)}
    end
  rescue
    # xmerl raises and exits on malformed input; any of it is "not XML".
    _error -> {:error, :malformed}
  catch
    :exit, _reason -> {:error, :malformed}
  end

  defp parse(_body), do: {:error, :malformed}
end
