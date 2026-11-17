defmodule KilnCMS.Backups.Destination.S3 do
  @moduledoc """
  A backup destination on S3-compatible object storage (#2221): AWS S3,
  Cloudflare R2, Backblaze B2, Wasabi, MinIO, Garage. Kiln's own, beside
  `KilnCMS.Backups.Destination.Local` and `KilnCMS.Backups.Destination.Rclone`.

  Settings: `endpoint` (an `https://` URL), `region`, `bucket`, `prefix`
  (optional) and `path_style`; secrets: `access_key_id` and
  `secret_access_key` (both stored encrypted and never shown again). A file
  is kept as `<prefix>/<subdir>/<name>`.

  Where it may connect is `KilnCMS.Backups.Destination.S3.Endpoint`'s to
  decide (`BACKUP_S3_PRIVATE_HOSTS` opens private hosts and `http://`); how a
  request is signed, sent, classified and retried is
  `KilnCMS.Backups.Destination.S3.Client`'s; how a file is copied, resumably,
  is `KilnCMS.Backups.Destination.S3.Multipart`'s. Every call parses the
  settings and pins the endpoint again.

  `test/1`, behind the form's Test button: `HeadBucket` (and the store's
  clock against this server's), a one-key `ListObjectsV2`, then a probe
  written under `<prefix>/.kiln-test/`, read back and deleted, whatever
  happened.

  `get/3` reads in ranged chunks (16 MiB) appended to the target file, so no
  file is held whole in memory, and checks the result against the object's
  sha256 metadata when it has one.

  The key needs `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`,
  `s3:ListBucket`, `s3:AbortMultipartUpload` and `s3:ListMultipartUploadParts`
  on the bucket and prefix. Without `s3:ListBucket` a missing object answers
  `403` rather than `404`, which reads as refused access.
  """

  use Kiln.BackupDestination

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.Destination
  alias KilnCMS.Backups.Destination.S3.{Client, Endpoint, Errors, Multipart, Xml}
  alias KilnCMS.Backups.Destination.S3.Errors.Error

  @subdirs ["db", "media"]
  @test_dir ".kiln-test"
  @meta "x-amz-meta-kiln-sha256"
  @default_get_chunk 16 * 1024 * 1024
  @list_page 1_000
  @max_list_pages 1_000

  @impl Kiln.BackupDestination
  def kind, do: "s3"

  @impl Kiln.BackupDestination
  def label, do: "S3-compatible storage"

  @impl Kiln.BackupDestination
  def fields do
    [
      %{
        name: "endpoint",
        type: :string,
        required?: true,
        help:
          "The store's https:// URL, e.g. https://s3.us-east-1.amazonaws.com or " <>
            "https://<account>.r2.cloudflarestorage.com."
      },
      %{
        name: "region",
        type: :string,
        required?: true,
        help: "The bucket's region, e.g. us-east-1 (auto for Cloudflare R2)."
      },
      %{name: "bucket", type: :string, required?: true, help: "The bucket's name."},
      %{
        name: "prefix",
        type: :string,
        required?: false,
        help: "A folder inside the bucket to keep backups under, e.g. kiln/site."
      },
      %{
        name: "path_style",
        type: :boolean,
        required?: false,
        help: "Address the bucket in the path, not the host name (MinIO, Garage)."
      },
      %{name: "access_key_id", type: :secret, required?: true, help: nil},
      %{name: "secret_access_key", type: :secret, required?: true, help: nil}
    ]
  end

  @impl Kiln.BackupDestination
  def supports, do: [:list, :delete, :resume]

  @impl Kiln.BackupDestination
  def validate(%Config{settings: settings, secrets: secrets}) do
    with {:ok, _endpoint} <- Endpoint.parse(settings), do: keys(secrets)
  end

  @impl Kiln.BackupDestination
  def test(config) do
    with {:ok, client} <- client(config, []) do
      client |> probe() |> reason()
    end
  end

  @impl Kiln.BackupDestination
  def put(config, %{subdir: subdir, name: name} = file, opts) do
    with :ok <- safe_ref(subdir, name),
         {:ok, client} <- client(config, opts) do
      key = Endpoint.object_key(client.endpoint, subdir, name)
      Multipart.put(client, key, file, Keyword.get(opts, :resume))
    end
  end

  @impl Kiln.BackupDestination
  def abort_upload(config, %{subdir: subdir, name: name, checkpoint: checkpoint}, opts) do
    with %{"upload_id" => upload_id} when is_binary(upload_id) and upload_id != "" <-
           checkpoint || %{},
         :ok <- safe_ref(subdir, name),
         {:ok, client} <- client(config, opts) do
      # The key is the settings' own, never the checkpoint's: what is
      # stored in the clear can't point an abort elsewhere.
      Multipart.abort(client, Endpoint.object_key(client.endpoint, subdir, name), upload_id)
    else
      %{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Kiln.BackupDestination
  def list(config) do
    with {:ok, client} <- client(config, []) do
      @subdirs
      |> Enum.reduce_while({:ok, []}, &list_into(client, &1, &2))
      |> reason()
    end
  end

  @impl Kiln.BackupDestination
  def get(config, %{subdir: subdir, name: name}, to) do
    with :ok <- safe_ref(subdir, name),
         {:ok, client} <- client(config, []) do
      client
      |> download(Endpoint.object_key(client.endpoint, subdir, name), to)
      |> reason()
    end
  end

  @impl Kiln.BackupDestination
  def delete(config, %{subdir: subdir, name: name}) do
    with :ok <- safe_ref(subdir, name),
         {:ok, client} <- client(config, []) do
      client
      |> delete_key(Endpoint.object_key(client.endpoint, subdir, name))
      |> reason()
    end
  end

  @impl Kiln.BackupDestination
  def describe(%Config{settings: settings}) do
    path =
      Enum.join(Enum.reject([settings["bucket"], prefix_text(settings)], &(&1 in [nil, ""])), "/")

    "s3://#{path} (#{host_text(settings)})"
  end

  @doc """
  Where `config` writes, normalized for
  `KilnCMS.Backups.Destination.overlap?/2`: `{:s3, host, port, bucket,
  prefix_segments}`, the host lowercased and the port its scheme's default
  when none is given. Read from the settings as stored, valid or not.
  """
  @spec location(Config.t()) :: {:s3, String.t(), non_neg_integer(), String.t(), [String.t()]}
  def location(%Config{settings: settings}) do
    {host, port} =
      case URI.new(String.trim(to_string(settings["endpoint"] || ""))) do
        {:ok, %URI{host: host, port: port}} when is_binary(host) ->
          {String.downcase(host) |> String.trim_trailing("."), port || 0}

        _invalid ->
          {"", 0}
      end

    segments =
      (settings["prefix"] || "")
      |> to_string()
      |> String.split("/", trim: true)

    {:s3, host, port, settings["bucket"] |> to_string() |> String.trim(), segments}
  end

  ## Calls

  defp client(%Config{settings: settings, secrets: secrets}, opts) do
    with {:ok, endpoint} <- permanent(Endpoint.parse(settings)),
         :ok <- permanent(keys(secrets)) do
      Client.new(
        endpoint,
        secrets["access_key_id"],
        secrets["secret_access_key"],
        deadline: Keyword.get(opts, :deadline)
      )
    end
  end

  defp permanent({:error, message}) when is_binary(message), do: {:error, {:permanent, message}}
  defp permanent(other), do: other

  defp keys(secrets) do
    id = secrets["access_key_id"]
    secret = secrets["secret_access_key"]

    cond do
      not is_binary(id) or id == "" -> {:error, "the access key id is missing"}
      not is_binary(secret) or secret == "" -> {:error, "the secret access key is missing"}
      String.match?(id, ~r/\s/) -> {:error, "the access key id must not contain spaces"}
      true -> :ok
    end
  end

  defp reason({:error, %Error{} = error}), do: {:error, Errors.to_reason(error)}
  defp reason(other), do: other

  defp safe_ref(subdir, name) do
    if subdir in @subdirs and is_binary(name) and name not in [".", ".."] and
         name =~ ~r/\A[A-Za-z0-9._-]{1,255}\z/,
       do: :ok,
       else: {:error, "#{inspect(subdir)}/#{inspect(name)} is not a backup file"}
  end

  ## Test

  defp probe(client) do
    with {:ok, response} <-
           step("checking the bucket", Client.call(client, :head_bucket, :head, "")),
         :ok <- clock(response),
         {:ok, _listed} <-
           step(
             "listing the bucket",
             Client.call(client, :list_objects, :get, "", [
               {"list-type", "2"},
               {"max-keys", "1"},
               {"prefix", Endpoint.key_prefix(client.endpoint, nil)}
             ])
           ) do
      write_probe(client)
    end
  end

  defp clock(%{headers: headers}) do
    if Errors.skewed?(headers), do: {:error, Errors.skew()}, else: :ok
  end

  defp write_probe(client) do
    hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    key = Endpoint.key_prefix(client.endpoint, nil) <> "#{@test_dir}/kiln-test-#{hex}.txt"
    body = "Kiln backup destination test #{hex}\n"
    md5 = Base.encode64(:crypto.hash(:md5, body))

    try do
      with {:ok, _put} <-
             step(
               "writing a test file",
               Client.call(client, :put_object, :put, key, [], [{"content-md5", md5}], body)
             ),
           {:ok, %{body: read}} <-
             step("reading the test file back", Client.call(client, :get_object, :get, key)) do
        if read == body,
          do: :ok,
          else: {:error, "the test file read back differs from what was written"}
      end
    after
      Client.call(client, :delete_object, :delete, key)
    end
  end

  defp step(_what, {:ok, _response} = ok), do: ok

  defp step(what, {:error, %Error{class: :not_found}}),
    do: {:error, {:permanent, "#{what}: the bucket does not exist"}}

  defp step(what, {:error, %Error{} = error}) do
    case Errors.to_reason(error) do
      {:permanent, message} -> {:error, {:permanent, "#{what}: #{message}"}}
      message -> {:error, "#{what}: #{message}"}
    end
  end

  defp step(what, {:error, :deadline}), do: {:error, "#{what}: ran out of time"}

  ## Listing

  defp list_into(client, subdir, {:ok, acc}) do
    case list_subdir(client, subdir) do
      {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp list_subdir(client, subdir), do: list_subdir(client, subdir, nil, [], 0)

  defp list_subdir(_client, _subdir, _token, _acc, page) when page >= @max_list_pages,
    do: {:error, "the bucket listing did not end after #{@max_list_pages} pages"}

  defp list_subdir(client, subdir, token, acc, page) do
    prefix = Endpoint.key_prefix(client.endpoint, subdir)

    query =
      [{"list-type", "2"}, {"max-keys", Integer.to_string(@list_page)}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    with {:ok, %{body: body}} <- Client.call(client, :list_objects, :get, "", query),
         {:ok, objects, next} <- listing(body) do
      acc = acc ++ Enum.flat_map(objects, &entry(&1, subdir, prefix))
      if next, do: list_subdir(client, subdir, next, acc, page + 1), else: {:ok, acc}
    end
  end

  defp listing(body) do
    case Xml.list_objects(body) do
      {:ok, objects, next} -> {:ok, objects, next}
      {:error, :malformed} -> {:error, "the bucket listing couldn't be read"}
    end
  end

  # Only a whole backup file directly in `<prefix>/<subdir>/`.
  defp entry(%{key: key, size: size, last_modified: modified}, subdir, prefix) do
    with ^prefix <> name <- key,
         false <- String.contains?(name, "/"),
         true <- size >= 0 and Destination.backup_file?(name) do
      [%{subdir: subdir, name: name, bytes: size, mtime: mtime(modified)}]
    else
      _ -> []
    end
  end

  defp mtime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  ## Reading

  # `to` is the core caller's own local path; nothing of the store's names
  # it. Read in ranges and appended, hashed on the way.
  # sobelow_skip ["Traversal.FileModule"]
  defp download(client, key, to) do
    with {:ok, head} <- Client.call(client, :head_object, :head, key),
         {:ok, size} <- size(head),
         {:ok, io} <- open_target(to) do
      result =
        try do
          fetch(client, key, io, size, 0, :crypto.hash_init(:sha256))
        after
          File.close(io)
        end

      with {:ok, digest} <- result,
           :ok <- check_digest(head, digest) do
        :ok
      else
        error ->
          File.rm(to)
          error
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp open_target(to) do
    case File.open(to, [:write, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, "couldn't write #{to}: #{inspect(reason)}"}
    end
  end

  defp size(head) do
    with value when is_binary(value) <- Client.header(head, "content-length"),
         {n, ""} when n >= 0 <- Integer.parse(value) do
      {:ok, n}
    else
      _ -> {:error, "the store didn't say how large the file is"}
    end
  end

  defp fetch(_client, _key, _io, size, at, sha) when at >= size and size > 0,
    do: fetch_done(sha)

  defp fetch(client, key, _io, 0, 0, sha) do
    case Client.call(client, :get_object, :get, key) do
      {:ok, %{body: ""}} -> fetch_done(sha)
      {:ok, _response} -> {:error, "the store sent more than the file's size"}
      {:error, _reason} = error -> error
    end
  end

  defp fetch(client, key, io, size, at, sha) do
    last = min(at + chunk() - 1, size - 1)
    range = [{"range", "bytes=#{at}-#{last}"}]

    with {:ok, response} <- Client.call(client, :get_object, :get, key, [], range),
         {:ok, data} <- ranged(response, at, last, size),
         :ok <- IO.binwrite(io, data) do
      fetch(client, key, io, size, at + byte_size(data), :crypto.hash_update(sha, data))
    end
  end

  defp fetch_done(sha), do: {:ok, sha |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  # A 206 of exactly the asked range, or a 200 of the whole file when it was
  # asked from the start (a store that ignores ranges).
  defp ranged(%{status: 206, body: body}, at, last, _size) when byte_size(body) == last - at + 1,
    do: {:ok, body}

  defp ranged(%{status: 200, body: body}, 0, _last, size) when byte_size(body) == size,
    do: {:ok, body}

  defp ranged(_response, _at, _last, _size),
    do: {:error, "the store sent a different part of the file than was asked for"}

  defp check_digest(head, digest) do
    case Client.header(head, @meta) do
      nil -> :ok
      ^digest -> :ok
      _other -> {:error, "the file read back doesn't match its sha256; it was not kept"}
    end
  end

  defp chunk do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:get_chunk_bytes, @default_get_chunk)
  end

  defp delete_key(client, key) do
    case Client.call(client, :delete_object, :delete, key) do
      {:ok, _response} -> :ok
      {:error, %Error{class: :not_found}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  ## Display

  defp prefix_text(settings) do
    case Endpoint.prefix(settings["prefix"]) do
      {:ok, segments} -> Enum.join(segments, "/")
      {:error, _message} -> to_string(settings["prefix"])
    end
  end

  defp host_text(settings) do
    case URI.new(to_string(settings["endpoint"] || "")) do
      {:ok, %URI{host: host}} when is_binary(host) -> host
      _ -> to_string(settings["endpoint"])
    end
  end
end
