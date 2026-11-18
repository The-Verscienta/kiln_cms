defmodule KilnCMS.Backups.Destination.S3.Multipart do
  @moduledoc """
  Copying one backup file to an S3 store (#2221), resumably (#2223).

    * **Already there?** A `HeadObject` first: an object of the same size
      whose `x-amz-meta-kiln-sha256` is the file's sha256 is
      `{:ok, :already_present}`, and nothing is sent.
    * **Small files** (under the part size) go in one `PutObject`, read into
      memory once, hashed there and compared with the sha256 the file was
      verified with before a byte is sent, with `Content-MD5` so the store
      checks what arrived.
    * **Larger files** go as a multipart upload of sequential parts of
      `part_size/2` (at least 16 MiB, more for a file that would otherwise
      need over 9,000 parts). The upload is created with the file's sha256
      as metadata and recorded (`save`) before any part is sent; each part
      carries `Content-MD5` and is recorded once the store acknowledges it.
      The checkpoint is `upload_id`, `key`, `part_size`, `parts_done`,
      `parts_digest`, `md5_etags` and `bytes_done`.
    * **Resuming** trusts nothing in the checkpoint until the store confirms
      it (a checkpoint with every part sent only retries the Complete): `ListParts` (paginated) must list parts `1..parts_done` with the
      expected sizes, and their `(number, etag, size)` must reproduce
      `parts_digest`, a running sha256 over exactly those. A part's ETag is
      compared with the local part's MD5 only when every ETag of the upload
      was one (`md5_etags`): a store that encrypts with KMS, or MinIO with
      SSE, answers ETags that are no MD5, and such an upload must still
      resume. Anything that doesn't match aborts that upload and starts a
      new one; an upload the store no longer has starts a new one. When the
      abort fails, no new upload is started (its first `save` would orphan
      the recorded one): the put answers a transient error and the next
      attempt tries again.
    * **Before completing**, the whole file's sha256, computed in the same
      read as the parts' MD5s (on a resume, the parts already sent are read
      again, not sent), must equal the verified one (ADR 0043).
    * **Just before completing**, `holds` (the off-site step's lease check,
      #3041) must answer `:ok`: a step that outlived its Cancel gets
      `{:error, :superseded}` and never completes an upload over the file
      the resumed backup sends. A check, not a fence: the Complete runs
      outside the lock (ADR 0045).
    * **After completing** (whatever the answer, a `200` carrying an
      `<Error>` included) a `HeadObject` decides: the object must have the
      file's size and sha256 metadata. An upload the store says it no longer
      has, whose object is there and matches, was completed by an earlier
      attempt.
    * **The deadline**: no part starts when the time left is less than the
      retry margin plus one and a half times the last part's duration; the
      answer is then `{:error, :deadline}`, with the progress saved.

  A `save` answering `{:error, :superseded}` ends the put; an upload created
  in this call is aborted first. Any failure of the first `save` after the
  upload is created aborts it too, since nothing would know of it. Without a
  `Resume` (a put Kiln doesn't record) every failure aborts the upload this
  call started.
  """

  alias KilnCMS.Backups.Destination.S3.{Client, Errors, Xml}
  alias KilnCMS.Backups.Destination.S3.Errors.Error
  alias KilnCMS.Backups.Retry

  @mib 1024 * 1024
  @default_min_part 16 * @mib
  @target_parts 9_000
  @max_parts 10_000
  @max_object 5 * 1024 * 1024 * 1024 * 1024
  @parts_page 1_000
  @meta "x-amz-meta-kiln-sha256"

  @doc "The largest object S3 stores: 5 TiB."
  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes, do: @max_object

  @doc """
  The smallest part, in bytes: 16 MiB, unless this module's config says
  otherwise (the test env sends small files in several parts).
  """
  @spec min_part_bytes() :: pos_integer()
  def min_part_bytes do
    :kiln_cms
    |> Application.get_env(KilnCMS.Backups.Destination.S3, [])
    |> Keyword.get(:min_part_bytes, @default_min_part)
  end

  @doc """
  The part size for a file of `bytes`: `min`, or, for a file that would
  need more than 9,000 parts of it, `bytes / 9000` rounded up to a whole
  MiB.
  """
  @spec part_size(non_neg_integer(), pos_integer()) :: pos_integer()
  def part_size(bytes, min \\ @default_min_part) do
    needed = div(bytes + @target_parts - 1, @target_parts)
    if needed <= min, do: min, else: div(needed + @mib - 1, @mib) * @mib
  end

  @doc """
  Copies `file` to `key`. `resume` is the `Kiln.BackupDestination.Resume`
  Kiln passed, or `nil`; `holds` is checked before a multipart upload is
  completed (`:ok` or `{:error, :superseded}`). Answers as
  `c:Kiln.BackupDestination.put/3` does.
  """
  @spec put(
          Client.t(),
          String.t(),
          map(),
          Kiln.BackupDestination.Resume.t() | nil,
          (-> :ok | {:error, term()})
        ) ::
          :ok | {:ok, :already_present} | {:error, term()}
  def put(%Client{} = client, key, file, resume, holds \\ fn -> :ok end) do
    if file.bytes > @max_object do
      {:error, {:permanent, "#{file.name} is larger than the 5 TiB an S3 object can hold"}}
    else
      client |> send_absent(key, file, {resume, holds}) |> reason()
    end
  end

  defp send_absent(client, key, file, {resume, holds}) do
    with :absent <- present(client, key, file) do
      if file.bytes < min_part_bytes(),
        do: single(client, key, file),
        else: multipart(%{client: client, key: key, file: file, resume: resume, holds: holds})
    end
  end

  defp reason({:error, %Error{} = error}), do: {:error, Errors.to_reason(error)}
  defp reason(other), do: other

  @doc """
  Whether `key` holds this very file: `{:ok, :already_present}` when it has
  the file's size and sha256 metadata, `:absent` when it is missing or
  differs, or the error that kept the store from saying.
  """
  @spec present(Client.t(), String.t(), map()) ::
          {:ok, :already_present} | :absent | {:error, term()}
  def present(client, key, file) do
    case Client.call(client, :head_object, :head, key) do
      {:ok, response} ->
        if matches?(response, file), do: {:ok, :already_present}, else: :absent

      {:error, %Error{class: :not_found}} ->
        :absent

      {:error, _reason} = error ->
        error
    end
  end

  defp matches?(response, file) do
    content_length(response) == file.bytes and
      Client.header(response, @meta) == String.downcase(file.sha256)
  end

  defp content_length(response) do
    with value when is_binary(value) <- Client.header(response, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  ## One request

  # `file.path` is the backup step's own verified file, not admin input.
  # sobelow_skip ["Traversal.FileModule"]
  defp single(client, key, file) do
    with {:ok, body} <- File.read(file.path),
         :ok <- same_content(body, file) do
      headers = [
        {"content-md5", Base.encode64(:crypto.hash(:md5, body))},
        {"content-type", "application/octet-stream"},
        {@meta, String.downcase(file.sha256)}
      ]

      with {:ok, _response} <- Client.call(client, :put_object, :put, key, [], headers, body),
           do: :ok
    else
      {:error, :changed} -> changed(file)
      {:error, reason} -> {:error, "couldn't read #{file.name}: #{inspect(reason)}"}
    end
  end

  defp same_content(body, file) do
    if byte_size(body) == file.bytes and sha256_hex(body) == String.downcase(file.sha256),
      do: :ok,
      else: {:error, :changed}
  end

  defp changed(file),
    do: {:error, "#{file.name} changed since it was verified; it was not sent"}

  ## Multipart

  defp multipart(ctx) do
    case resumed(ctx) do
      {:ok, state} -> with_file(ctx, state)
      :fresh -> fresh(ctx)
      {:replace, upload_id} -> with :ok <- abort_replaced(ctx, upload_id), do: fresh(ctx)
      {:error, _reason} = error -> error
    end
  end

  # A recorded upload that is about to be replaced by a new one is aborted
  # first. If that fails, no new upload is created: its first `save` would
  # overwrite the recorded upload id, and nothing would ever abort the old
  # one. The error is transient; the next attempt tries again.
  defp abort_replaced(ctx, upload_id) do
    case abort(ctx.client, ctx.key, upload_id) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "couldn't abort the earlier upload of #{ctx.file.name} before starting over " <>
           "(#{reason_text(reason)}); the next attempt tries again"}
    end
  end

  defp reason_text({:permanent, message}), do: message
  defp reason_text(message) when is_binary(message), do: message
  defp reason_text(reason), do: inspect(reason)

  defp fresh(ctx) do
    with {:ok, state} <- create(ctx), do: with_file(ctx, state)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp with_file(ctx, state) do
    case File.open(ctx.file.path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          send_from(ctx, state, io)
        after
          File.close(io)
        end

      {:error, reason} ->
        give_up(ctx, state, {:error, "couldn't read #{ctx.file.name}: #{inspect(reason)}"})
    end
  end

  defp send_from(ctx, state, io) do
    case hash_sent(ctx, state, io) do
      {:ok, sha} ->
        send_parts(ctx, state, io, sha, state.done + 1)

      :mismatch ->
        with :ok <- abort_replaced(ctx, state.upload_id),
             {:ok, state} <- create(ctx),
             do: send_parts(ctx, state, io, sha_init(), 1)

      {:error, _reason} = error ->
        give_up(ctx, state, error)
    end
  end

  # The whole-file hash covers the parts a resumed upload already holds:
  # read again (not sent), each checked against its ETag when the upload's
  # ETags are MD5s.
  defp hash_sent(ctx, state, io) do
    Enum.reduce_while(1..state.done//1, {:ok, sha_init()}, &hash_held(ctx, state, io, &1, &2))
  end

  defp hash_held(ctx, state, io, number, {:ok, sha}) do
    with {:ok, data} <- read_part(io, ctx.file, state.part_size, number),
         :ok <- same_part(state, number, data) do
      {:cont, {:ok, :crypto.hash_update(sha, data)}}
    else
      other -> {:halt, other}
    end
  end

  defp same_part(%{md5?: true, etags: etags}, number, data),
    do: if(Map.get(etags, number) == md5_hex(data), do: :ok, else: :mismatch)

  defp same_part(_state, _number, _data), do: :ok

  defp send_parts(ctx, state, io, sha, number) do
    if number > parts(ctx.file.bytes, state.part_size) do
      with {:error, _reason} = error <- finish(ctx, state, sha), do: give_up(ctx, state, error)
    else
      with :ok <- time_left(ctx, state),
           {:ok, data} <- read_part(io, ctx.file, state.part_size, number),
           {:ok, state} <- send_part(ctx, state, number, data) do
        send_parts(ctx, state, io, :crypto.hash_update(sha, data), number + 1)
      else
        {:error, _reason} = error -> give_up(ctx, state, error)
      end
    end
  end

  defp send_part(ctx, state, number, data) do
    md5 = :crypto.hash(:md5, data)
    started = System.monotonic_time(:millisecond)

    query = [{"partNumber", Integer.to_string(number)}, {"uploadId", state.upload_id}]
    headers = [{"content-md5", Base.encode64(md5)}]

    with {:ok, response} <-
           Client.call(ctx.client, :upload_part, :put, ctx.key, query, headers, data),
         etag when etag != "" <- response |> Client.header("etag") |> Xml.unquote_etag() do
      state = %{
        state
        | done: number,
          digest: digest(state.digest, number, etag, byte_size(data)),
          etags: Map.put(state.etags, number, etag),
          md5?: state.md5? and etag == Base.encode16(md5, case: :lower),
          bytes_done: state.bytes_done + byte_size(data),
          last_ms: System.monotonic_time(:millisecond) - started
      }

      with :ok <- save(ctx, state), do: {:ok, state}
    else
      "" -> {:error, "the store acknowledged a part without an ETag"}
      {:error, _reason} = error -> error
    end
  end

  defp finish(ctx, state, sha) do
    if sha_hex(sha) == String.downcase(ctx.file.sha256) do
      with :ok <- ctx.holds.(), do: complete(ctx, state)
    else
      abort(ctx.client, ctx.key, state.upload_id)
      changed(ctx.file)
    end
  end

  defp complete(ctx, state) do
    body =
      state.etags
      |> Enum.sort()
      |> Xml.complete_body()

    query = [{"uploadId", state.upload_id}]
    headers = [{"content-type", "application/xml"}]

    answer =
      Client.retry(ctx.client, fn ->
        with {:ok, response} <-
               Client.request(ctx.client, :complete, :post, ctx.key, query, headers, body) do
          completed(response)
        end
      end)

    # Whatever the answer, the object decides.
    case {present(ctx.client, ctx.key, ctx.file), answer} do
      {{:ok, :already_present}, _answer} ->
        :ok

      {_absent_or_error, {:error, _reason} = error} ->
        error

      {{:error, _reason} = error, _ok} ->
        error

      {:absent, _ok} ->
        {:error, "the store completed the upload, but the file it holds doesn't match"}
    end
  end

  # A `200` to CompleteMultipartUpload can still carry an `<Error>`.
  defp completed(%{body: body} = response) do
    if Xml.root(body) == "Error",
      do: {:error, Errors.classify(500, [], body)},
      else: {:ok, response}
  end

  ## Creating and resuming

  defp create(ctx) do
    headers = [
      {"content-type", "application/octet-stream"},
      {@meta, String.downcase(ctx.file.sha256)}
    ]

    with {:ok, response} <-
           Client.call(ctx.client, :create_multipart, :post, ctx.key, [{"uploads", ""}], headers),
         {:ok, upload_id} <- upload_id(response) do
      state = %{
        upload_id: upload_id,
        part_size: part_size(ctx.file.bytes, min_part_bytes()),
        done: 0,
        digest: "",
        etags: %{},
        md5?: true,
        bytes_done: 0,
        last_ms: 0,
        created?: true
      }

      # Recorded before any data is sent; unrecorded, it is aborted here.
      case save(ctx, state) do
        :ok ->
          {:ok, state}

        {:error, _reason} = error ->
          abort(ctx.client, ctx.key, upload_id)
          error
      end
    end
  end

  defp upload_id(%{body: body}) do
    case Xml.upload_id(body) do
      {:ok, id} ->
        {:ok, id}

      {:error, :malformed} ->
        {:error, "the store's answer to starting an upload had no upload id"}
    end
  end

  defp resumed(%{resume: %{checkpoint: %{} = checkpoint}} = ctx) do
    with {:ok, state} <- checkpoint_state(ctx, checkpoint),
         {:ok, listed} <- list_parts(ctx, state) do
      verify(ctx, state, listed)
    else
      :fresh ->
        :fresh

      {:replace, _upload_id} = replace ->
        replace

      {:error, %Error{class: :upload_gone}} ->
        :fresh

      {:error, _reason} = error ->
        error
    end
  end

  defp resumed(_ctx), do: :fresh

  defp checkpoint_state(ctx, checkpoint) do
    with %{
           "upload_id" => id,
           "key" => key,
           "part_size" => size,
           "parts_done" => done,
           "parts_digest" => digest
         }
         when is_binary(id) and id != "" and key == ctx.key and is_integer(size) and size > 0 and
                is_integer(done) and done >= 0 and is_binary(digest) <- checkpoint,
         true <- parts(ctx.file.bytes, size) <= @max_parts and done <= parts(ctx.file.bytes, size) do
      {:ok,
       %{
         upload_id: id,
         part_size: size,
         done: done,
         digest: digest,
         etags: %{},
         md5?: checkpoint["md5_etags"] == true,
         bytes_done: min(done * size, ctx.file.bytes),
         last_ms: 0,
         created?: false
       }}
    else
      _unusable -> unusable(checkpoint)
    end
  end

  # A checkpoint that can't be resumed still names an upload to abort.
  defp unusable(%{"upload_id" => id}) when is_binary(id) and id != "", do: {:replace, id}
  defp unusable(_checkpoint), do: :fresh

  # Parts 1..done, as the store lists them, must reproduce the digest.
  defp verify(ctx, state, listed) do
    by_number = Map.new(listed, &{&1.number, &1})

    expected = &expected_size(ctx.file.bytes, state.part_size, &1)

    digest =
      Enum.reduce_while(1..state.done//1, "", fn number, acc ->
        listed_part(Map.get(by_number, number), expected.(number), number, acc)
      end)

    if digest == state.digest do
      etags = for number <- 1..state.done//1, into: %{}, do: {number, by_number[number].etag}
      {:ok, %{state | etags: etags}}
    else
      {:replace, state.upload_id}
    end
  end

  defp listed_part(%{etag: etag, size: size}, size, number, acc) when etag != "",
    do: {:cont, digest(acc, number, etag, size)}

  defp listed_part(_missing_or_other_size, _expected, _number, _acc), do: {:halt, :mismatch}

  defp list_parts(ctx, state), do: list_parts(ctx, state, nil, [], 0)

  # Bounded: 10,000 parts fill at most 10 pages.
  defp list_parts(_ctx, _state, _marker, _acc, page) when page > @max_parts / @parts_page,
    do: {:error, "the store listed the upload's parts without end"}

  defp list_parts(ctx, state, marker, acc, page) do
    query =
      [{"max-parts", Integer.to_string(@parts_page)}, {"uploadId", state.upload_id}] ++
        if(marker, do: [{"part-number-marker", marker}], else: [])

    with {:ok, %{body: body}} <- Client.call(ctx.client, :list_parts, :get, ctx.key, query),
         {:ok, parts, next} <- parts_page(body) do
      acc = acc ++ parts

      if next == nil or Enum.any?(parts, &(&1.number >= state.done)),
        do: {:ok, acc},
        else: list_parts(ctx, state, next, acc, page + 1)
    end
  end

  defp parts_page(body) do
    case Xml.list_parts(body) do
      {:ok, parts, next} -> {:ok, parts, next}
      {:error, :malformed} -> {:error, "the store's list of the upload's parts couldn't be read"}
    end
  end

  ## Progress

  defp save(%{resume: %{save: save}} = ctx, state) when is_function(save, 1) do
    save.(checkpoint(ctx.key, state))
  end

  defp save(_ctx, _state), do: :ok

  defp checkpoint(key, state) do
    %{
      upload_id: state.upload_id,
      key: key,
      part_size: state.part_size,
      parts_done: state.done,
      parts_digest: state.digest,
      md5_etags: state.md5?,
      bytes_done: state.bytes_done
    }
  end

  # On the way out with an error: a superseded put aborts an upload it
  # created itself; a put nothing records aborts whatever it started.
  defp give_up(ctx, state, {:error, reason} = error) do
    cond do
      reason == :superseded and state.created? -> abort(ctx.client, ctx.key, state.upload_id)
      ctx.resume == nil -> abort(ctx.client, ctx.key, state.upload_id)
      true -> :ok
    end

    error
  end

  defp time_left(%{client: %Client{deadline: nil}}, _state), do: :ok

  defp time_left(%{client: %Client{deadline: deadline}}, state) do
    needed = Retry.margin_ms() + div(state.last_ms * 3, 2)

    if System.monotonic_time(:millisecond) + needed <= deadline,
      do: :ok,
      else: {:error, :deadline}
  end

  @doc """
  Aborts `upload_id` on `key`. An upload the store no longer has is
  success.
  """
  @spec abort(Client.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def abort(client, key, upload_id) do
    case Client.call(client, :abort_multipart, :delete, key, [{"uploadId", upload_id}]) do
      {:ok, _response} -> :ok
      {:error, %Error{class: class}} when class in [:upload_gone, :not_found] -> :ok
      {:error, %Error{} = error} -> {:error, Errors.to_reason(error)}
      {:error, _reason} = error -> error
    end
  end

  ## Arithmetic

  defp parts(0, _size), do: 1
  defp parts(bytes, size), do: div(bytes + size - 1, size)

  defp expected_size(bytes, size, number), do: min(size, bytes - (number - 1) * size)

  defp read_part(io, file, size, number) do
    length = expected_size(file.bytes, size, number)

    case :file.pread(io, (number - 1) * size, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      {:ok, _short} -> changed(file)
      :eof -> changed(file)
      {:error, reason} -> {:error, "couldn't read #{file.name}: #{inspect(reason)}"}
    end
  end

  @doc """
  The running digest of acknowledged parts: sha256 (hex) of the previous
  digest and `number:etag:size`. `""` before the first part.
  """
  @spec digest(String.t(), pos_integer(), String.t(), non_neg_integer()) :: String.t()
  def digest(previous, number, etag, size),
    do: sha256_hex("#{previous}|#{number}:#{etag}:#{size}")

  defp sha_init, do: :crypto.hash_init(:sha256)
  defp sha_hex(sha), do: sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
  defp sha256_hex(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
  defp md5_hex(data), do: :md5 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end
