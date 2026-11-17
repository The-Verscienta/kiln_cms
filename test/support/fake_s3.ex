defmodule KilnCMS.Test.FakeS3 do
  @moduledoc """
  An in-memory S3 store behind the `Req.Test` stub an S3 backup destination
  sends to (`KilnCMS.Backups.Destination.S3`, #2221): buckets, objects with
  metadata, multipart uploads with `ListParts`, ranged reads, and failures
  injected per operation.

  It checks what a real store checks: a signed `Authorization` header, the
  `x-amz-content-sha256` of the body, and `Content-MD5` when sent (a
  mismatch is `BadDigest`). Path-style and virtual-hosted requests both
  work.

  Options of `start/1`:

    * `:buckets` — the buckets that exist (default `["kiln-backups"]`);
    * `:etags` — `:md5` (default) or `:opaque`, ETags that are 32 hex digits
      but no MD5, as SSE-KMS and MinIO with SSE answer;
    * `:skew` — seconds the store's `Date` header is off by;
    * `:list_page` and `:parts_page` — the most keys or parts one listing
      page holds, whatever was asked.

  `inject/4` makes the next matching request of an operation fail (see its
  doc). Every injected error body carries a `<Message>` with
  `"STORE-MESSAGE"` in it, which nothing of Kiln's may repeat.
  """

  import Plug.Conn

  @stub KilnCMS.Backups.Destination.S3

  @doc "Starts a store for the calling test and routes the stub to it. Answers its pid."
  @spec start(keyword()) :: pid()
  def start(opts \\ []) do
    state = %{
      buckets: MapSet.new(Keyword.get(opts, :buckets, ["kiln-backups"])),
      objects: %{},
      uploads: %{},
      etags: Keyword.get(opts, :etags, :md5),
      skew: Keyword.get(opts, :skew, 0),
      list_page: Keyword.get(opts, :list_page, 1_000),
      parts_page: Keyword.get(opts, :parts_page, 1_000),
      injections: [],
      log: [],
      counter: 0
    }

    pid = ExUnit.Callbacks.start_supervised!({Agent, fn -> state end}, id: make_ref())
    Req.Test.stub(@stub, fn conn -> handle(pid, conn) end)
    pid
  end

  @doc """
  The next request of `op` (`:head_bucket`, `:head_object`, `:list_objects`,
  `:get_object`, `:put_object`, `:create_multipart`, `:upload_part`,
  `:list_parts`, `:complete`, `:abort_multipart`, `:delete_object`) answers
  `response` instead:

    * `{:error, status, code}` — an S3 error body with that `<Code>`;
    * `{:status, status, headers}` — an empty body;
    * `:drop` — the connection closes;
    * `{:after, response}` — the operation is done, then `response` answered.

  `opts`: `:times` (1, or `:infinity`) and `:skip` (let this many matching
  requests through first).
  """
  @spec inject(pid(), atom(), term(), keyword()) :: :ok
  def inject(pid, op, response, opts \\ []) do
    injection = %{
      op: op,
      response: response,
      times: Keyword.get(opts, :times, 1),
      skip: Keyword.get(opts, :skip, 0)
    }

    Agent.update(pid, &%{&1 | injections: &1.injections ++ [injection]})
  end

  @doc "The object `key` of `bucket`: `%{body, meta}`, or `nil`."
  @spec object(pid(), String.t(), String.t()) :: map() | nil
  def object(pid, bucket \\ "kiln-backups", key),
    do: Agent.get(pid, &Map.get(&1.objects, {bucket, key}))

  @doc "Every object key of `bucket`, sorted."
  @spec keys(pid(), String.t()) :: [String.t()]
  def keys(pid, bucket \\ "kiln-backups") do
    Agent.get(pid, fn state ->
      for {{^bucket, key}, _object} <- state.objects, do: key
    end)
    |> Enum.sort()
  end

  @doc "The open multipart uploads, by id."
  @spec uploads(pid()) :: map()
  def uploads(pid), do: Agent.get(pid, & &1.uploads)

  @doc "Every request so far, oldest first, as `{op, key, query}`."
  @spec requests(pid()) :: [{atom(), String.t(), map()}]
  def requests(pid), do: pid |> Agent.get(& &1.log) |> Enum.reverse()

  @doc "How many requests of `op` were made."
  @spec count(pid(), atom()) :: non_neg_integer()
  def count(pid, op), do: pid |> requests() |> Enum.count(&(elem(&1, 0) == op))

  @doc "Stores an object directly."
  @spec put_object(pid(), String.t(), binary(), map(), String.t()) :: :ok
  def put_object(pid, key, body, meta \\ %{}, bucket \\ "kiln-backups") do
    Agent.update(pid, fn state ->
      %{state | objects: Map.put(state.objects, {bucket, key}, object_of(body, meta, state))}
    end)
  end

  ## The plug

  @doc false
  def handle(pid, conn) do
    {:ok, body, conn} = read_body(conn, length: 1_000_000_000)
    query = URI.decode_query(conn.query_string)
    {bucket, key} = target(pid, conn)
    op = op(conn.method, key, query)

    Agent.update(pid, &%{&1 | log: [{op, key, query} | &1.log]})

    case take_injection(pid, op) do
      nil -> checked(pid, conn, op, bucket, key, query, body)
      {:after, response} -> after_op(pid, conn, op, bucket, key, query, body, response)
      response -> injected(pid, conn, response)
    end
  end

  defp after_op(pid, conn, op, bucket, key, query, body, response) do
    _done = checked(pid, conn, op, bucket, key, query, body)
    injected(pid, conn, response)
  end

  defp injected(_pid, conn, :drop), do: Req.Test.transport_error(conn, :closed)

  defp injected(pid, conn, {:error, status, code}), do: error(pid, conn, status, code)

  defp injected(pid, conn, {:status, status, headers}) do
    conn
    |> date(pid)
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_resp_header(c, k, v) end))
    |> send_resp(status, "")
  end

  defp injected(pid, conn, {:ok_error, code}) do
    conn |> date(pid) |> send_resp(200, error_body(code))
  end

  defp take_injection(pid, op) do
    Agent.get_and_update(pid, fn state ->
      case Enum.find_index(state.injections, &(&1.op == op)) do
        nil -> {nil, state}
        index -> consume(state, index, Enum.at(state.injections, index))
      end
    end)
  end

  defp consume(state, index, %{skip: skip} = injection) when skip > 0,
    do: {nil, put_in_list(state, index, %{injection | skip: skip - 1})}

  defp consume(state, _index, %{times: :infinity, response: response}), do: {response, state}

  defp consume(state, index, %{times: times, response: response}) when times <= 1,
    do: {response, %{state | injections: List.delete_at(state.injections, index)}}

  defp consume(state, index, %{times: times, response: response} = injection),
    do: {response, put_in_list(state, index, %{injection | times: times - 1})}

  defp put_in_list(state, index, injection),
    do: %{state | injections: List.replace_at(state.injections, index, injection)}

  defp target(pid, conn) do
    buckets = Agent.get(pid, & &1.buckets)
    segments = String.split(conn.request_path, "/", trim: true)

    virtual =
      Enum.find(buckets, fn bucket -> String.starts_with?(conn.host, bucket <> ".") end)

    case {virtual, segments} do
      {bucket, _segments} when is_binary(bucket) -> {bucket, Enum.join(segments, "/")}
      {nil, [bucket | rest]} -> {bucket, Enum.join(rest, "/")}
      {nil, []} -> {nil, ""}
    end
  end

  defp op("HEAD", "", _query), do: :head_bucket
  defp op("HEAD", _key, _query), do: :head_object
  defp op("GET", "", _query), do: :list_objects
  defp op("GET", _key, %{"uploadId" => _}), do: :list_parts
  defp op("GET", _key, _query), do: :get_object
  defp op("PUT", _key, %{"uploadId" => _}), do: :upload_part
  defp op("PUT", _key, _query), do: :put_object
  defp op("POST", _key, %{"uploads" => _}), do: :create_multipart
  defp op("POST", _key, %{"uploadId" => _}), do: :complete
  defp op("DELETE", _key, %{"uploadId" => _}), do: :abort_multipart
  defp op("DELETE", _key, _query), do: :delete_object

  # The checks a real store makes before doing anything.
  defp checked(pid, conn, op, bucket, key, query, body) do
    sha = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

    cond do
      not signed?(conn) ->
        error(pid, conn, 403, "AccessDenied")

      header(conn, "x-amz-content-sha256") != sha ->
        error(pid, conn, 400, "XAmzContentSHA256Mismatch")

      (md5 = header(conn, "content-md5")) && md5 != Base.encode64(:crypto.hash(:md5, body)) ->
        error(pid, conn, 400, "BadDigest")

      not MapSet.member?(Agent.get(pid, & &1.buckets), bucket) ->
        if conn.method == "HEAD",
          do: conn |> date(pid) |> send_resp(404, ""),
          else: error(pid, conn, 404, "NoSuchBucket")

      true ->
        perform(pid, conn, op, bucket, key, query, body)
    end
  end

  defp signed?(conn) do
    case header(conn, "authorization") do
      "AWS4-HMAC-SHA256 Credential=" <> _rest -> true
      _ -> false
    end
  end

  defp perform(pid, conn, :head_bucket, _bucket, _key, _query, _body),
    do: conn |> date(pid) |> send_resp(200, "")

  defp perform(pid, conn, :head_object, bucket, key, _query, _body) do
    case object(pid, bucket, key) do
      nil ->
        conn |> date(pid) |> send_resp(404, "")

      object ->
        conn
        |> date(pid)
        |> object_headers(object)
        |> put_resp_header("content-length", Integer.to_string(byte_size(object.body)))
        |> send_resp(200, "")
    end
  end

  defp perform(pid, conn, :get_object, bucket, key, _query, _body) do
    case object(pid, bucket, key) do
      nil ->
        error(pid, conn, 404, "NoSuchKey")

      object ->
        conn = conn |> date(pid) |> object_headers(object)

        case header(conn, "range") do
          "bytes=" <> range ->
            [from, to] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
            to = min(to, byte_size(object.body) - 1)
            slice = binary_part(object.body, from, to - from + 1)

            conn
            |> put_resp_header("content-range", "bytes #{from}-#{to}/#{byte_size(object.body)}")
            |> send_resp(206, slice)

          nil ->
            send_resp(conn, 200, object.body)
        end
    end
  end

  defp perform(pid, conn, :put_object, bucket, key, _query, body) do
    meta = meta(conn)

    Agent.update(pid, fn state ->
      %{state | objects: Map.put(state.objects, {bucket, key}, object_of(body, meta, state))}
    end)

    object = object(pid, bucket, key)
    conn |> date(pid) |> put_resp_header("etag", ~s("#{object.etag}")) |> send_resp(200, "")
  end

  defp perform(pid, conn, :delete_object, bucket, key, _query, _body) do
    Agent.update(pid, &%{&1 | objects: Map.delete(&1.objects, {bucket, key})})
    conn |> date(pid) |> send_resp(204, "")
  end

  defp perform(pid, conn, :create_multipart, bucket, key, _query, _body) do
    meta = meta(conn)

    id =
      Agent.get_and_update(pid, fn state ->
        id = "upload-#{state.counter + 1}-#{Base.encode16(:crypto.strong_rand_bytes(4))}"

        upload = %{bucket: bucket, key: key, meta: meta, parts: %{}}
        {id, %{state | counter: state.counter + 1, uploads: Map.put(state.uploads, id, upload)}}
      end)

    xml(pid, conn, 200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>#{bucket}</Bucket><Key>#{key}</Key><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>
    """)
  end

  defp perform(pid, conn, :upload_part, _bucket, _key, query, body) do
    id = query["uploadId"]
    number = String.to_integer(query["partNumber"])

    case Agent.get(pid, &Map.get(&1.uploads, id)) do
      nil ->
        error(pid, conn, 404, "NoSuchUpload")

      _upload ->
        etag = etag(pid, body)

        Agent.update(pid, fn state ->
          update_in(state.uploads[id].parts, &Map.put(&1, number, %{etag: etag, body: body}))
        end)

        conn |> date(pid) |> put_resp_header("etag", ~s("#{etag}")) |> send_resp(200, "")
    end
  end

  defp perform(pid, conn, :list_parts, _bucket, _key, query, _body) do
    id = query["uploadId"]

    case Agent.get(pid, &Map.get(&1.uploads, id)) do
      nil ->
        error(pid, conn, 404, "NoSuchUpload")

      upload ->
        page =
          min(String.to_integer(query["max-parts"] || "1000"), Agent.get(pid, & &1.parts_page))

        marker = String.to_integer(query["part-number-marker"] || "0")

        numbers = upload.parts |> Map.keys() |> Enum.sort() |> Enum.filter(&(&1 > marker))
        {shown, rest} = Enum.split(numbers, page)

        parts =
          Enum.map(shown, fn n ->
            part = upload.parts[n]

            "<Part><PartNumber>#{n}</PartNumber><ETag>&quot;#{part.etag}&quot;</ETag>" <>
              "<Size>#{byte_size(part.body)}</Size></Part>"
          end)

        next =
          if rest != [], do: "<NextPartNumberMarker>#{List.last(shown)}</NextPartNumberMarker>"

        xml(pid, conn, 200, """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><UploadId>#{id}</UploadId><IsTruncated>#{rest != []}</IsTruncated>#{next}#{parts}</ListPartsResult>
        """)
    end
  end

  defp perform(pid, conn, :complete, bucket, key, query, body) do
    id = query["uploadId"]

    asked =
      ~r{<PartNumber>(\d+)</PartNumber><ETag>(?:&quot;|")([^&"<]+)(?:&quot;|")</ETag>}
      |> Regex.scan(body)
      |> Enum.map(fn [_, n, etag] -> {String.to_integer(n), etag} end)

    case Agent.get(pid, &Map.get(&1.uploads, id)) do
      nil ->
        error(pid, conn, 404, "NoSuchUpload")

      upload ->
        complete(pid, conn, {bucket, key, id}, upload, asked)
    end
  end

  defp perform(pid, conn, :abort_multipart, _bucket, _key, query, _body) do
    id = query["uploadId"]

    if Agent.get(pid, &Map.has_key?(&1.uploads, id)) do
      Agent.update(pid, &%{&1 | uploads: Map.delete(&1.uploads, id)})
      conn |> date(pid) |> send_resp(204, "")
    else
      error(pid, conn, 404, "NoSuchUpload")
    end
  end

  defp perform(pid, conn, :list_objects, bucket, _key, query, _body) do
    prefix = query["prefix"] || ""
    page = min(String.to_integer(query["max-keys"] || "1000"), Agent.get(pid, & &1.list_page))
    after_key = query["continuation-token"] || ""

    matching =
      pid
      |> keys(bucket)
      |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 > after_key))

    {shown, rest} = Enum.split(matching, page)
    truncated = rest != [] and shown != []

    contents =
      Enum.map(shown, fn key ->
        object = object(pid, bucket, key)

        "<Contents><Key>#{key}</Key><LastModified>2026-11-17T10:00:00.000Z</LastModified>" <>
          "<ETag>&quot;#{object.etag}&quot;</ETag><Size>#{byte_size(object.body)}</Size></Contents>"
      end)

    next = if truncated, do: "<NextContinuationToken>#{List.last(shown)}</NextContinuationToken>"

    xml(pid, conn, 200, """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>#{bucket}</Name><Prefix>#{prefix}</Prefix><KeyCount>#{length(shown)}</KeyCount><IsTruncated>#{truncated}</IsTruncated>#{next}#{contents}</ListBucketResult>
    """)
  end

  defp complete(pid, conn, {bucket, key, id}, upload, asked) do
    if asked != [] and Enum.all?(asked, fn {n, etag} -> upload.parts[n][:etag] == etag end) do
      data = Enum.map_join(asked, fn {n, _etag} -> upload.parts[n].body end)

      Agent.update(pid, fn state ->
        object = %{object_of(data, upload.meta, state) | etag: "multipart-#{length(asked)}"}

        %{
          state
          | objects: Map.put(state.objects, {bucket, key}, object),
            uploads: Map.delete(state.uploads, id)
        }
      end)

      xml(pid, conn, 200, """
      <?xml version="1.0" encoding="UTF-8"?>
      <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>#{bucket}</Bucket><Key>#{key}</Key></CompleteMultipartUploadResult>
      """)
    else
      error(pid, conn, 400, "InvalidPart")
    end
  end

  ## Helpers

  defp object_of(body, meta, state) do
    %{body: body, meta: meta, etag: etag_for(state.etags, body)}
  end

  defp etag(pid, body), do: etag_for(Agent.get(pid, & &1.etags), body)

  defp etag_for(:md5, body), do: :md5 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp etag_for(:opaque, body),
    do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 32)

  defp meta(conn) do
    for {"x-amz-meta-" <> name, value} <- conn.req_headers, into: %{}, do: {name, value}
  end

  defp object_headers(conn, object) do
    conn = put_resp_header(conn, "etag", ~s("#{object.etag}"))

    Enum.reduce(object.meta, conn, fn {name, value}, conn ->
      put_resp_header(conn, "x-amz-meta-" <> name, value)
    end)
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp date(conn, pid) do
    skew = Agent.get(pid, & &1.skew)
    now = DateTime.add(DateTime.utc_now(), skew)
    put_resp_header(conn, "date", Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S GMT"))
  end

  defp xml(pid, conn, status, body) do
    conn
    |> date(pid)
    |> put_resp_content_type("application/xml")
    |> send_resp(status, String.trim(body))
  end

  defp error(pid, conn, status, code) do
    if conn.method == "HEAD",
      do: conn |> date(pid) |> send_resp(status, ""),
      else: xml(pid, conn, status, error_body(code))
  end

  @doc "An S3 error body with `code`, its `<Message>` the store's own words."
  @spec error_body(String.t()) :: String.t()
  def error_body(code) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>#{code}</Code><Message>STORE-MESSAGE for #{code}: &lt;script&gt;</Message><RequestId>R1</RequestId></Error>
    """
  end
end
