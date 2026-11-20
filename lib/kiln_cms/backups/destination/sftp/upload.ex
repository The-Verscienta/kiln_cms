defmodule KilnCMS.Backups.Destination.Sftp.Upload do
  @moduledoc """
  How an SFTP destination copies one file (#2222): under a temporary name,
  then renamed into place, so a later listing never sees half a file.

  ## Resumable (`opts[:resume]`, ADR 0068)

    * A first attempt picks a random 16-hex token and saves it
      (`%{"token" => …, "bytes_done" => 0}`) **before** the temporary file
      `<name>.<token>.partial` is created, so a file a crash leaves is
      always recorded and `abort_upload/3` can find it. OTP's SFTP client
      opens a file for writing with `CREAT|TRUNC` and can't ask for `EXCL`,
      so the name is checked to be free first; with a fresh random token
      it can only be taken by a race nobody wins on purpose.
    * Progress is saved after acknowledged writes, every 64 MiB or 30 s.
    * A resumed attempt trusts only a token of 16 hex digits; every path is
      built from the settings and that token, never read from the
      checkpoint. The temporary file must be a regular file (never a link);
      the upload resumes from the smaller of its size and the saved
      progress, rounded down to 1 MiB, once the last MiB before that point
      reads back the same as the local file. Anything else starts over with
      a new token.
  Within 30 s of the call's deadline it stops, saves its progress and
  answers `{:error, :deadline}`.

  ## Not resumable

  Without `opts[:resume]` (a call outside a backup step) the temporary name
  is `KilnCMS.Backups.Artifact.partial_name/2` with the step's `:tag`. A
  later put to the same subdirectory removes such files once older than
  `KilnCMS.Backups.Retention.partial_grace_s/0`; a token's file is left to
  `abort_upload/3`, which only Kiln's upload sweep calls.

  ## Finishing

  The temporary file's size must be the file's; then the step's lease
  (`opts[:holds]`) is checked, and the file renamed into place. What lands
  is verified by size and, on resume, by the read-back of the last MiB
  before the resume point: weaker than Local's whole-file hash, which over
  SFTP would read every byte back over the network. With no `fsync@openssh.com`,
  a server crash right after the rename may leave a short file there.

  A file already in place with the same size and sha256 (read back whole
  only when the size matches) is not sent again: `{:ok, :already_present}`.
  """

  alias Kiln.BackupDestination.Resume
  alias KilnCMS.Backups.{Artifact, Destination, Retention}
  alias KilnCMS.Backups.Destination.Sftp.{Errors, Files, Session, Target}

  @token ~r/\A[0-9a-f]{16}\z/
  @resume_unit 1024 * 1024
  @window 16
  @checkpoint_bytes 64 * 1024 * 1024
  @checkpoint_ms :timer.seconds(30)
  @stop_ms :timer.seconds(30)

  @doc "Whether `token` is one a resumable upload makes: 16 lowercase hex digits."
  @spec token?(term()) :: boolean()
  def token?(token) when is_binary(token), do: Regex.match?(@token, token)
  def token?(_token), do: false

  @doc "The temporary name of `name` under `token`."
  @spec token_partial(String.t(), String.t()) :: String.t()
  def token_partial(name, token), do: name <> "." <> token <> ".partial"

  @doc """
  Copies `file` (`Kiln.BackupDestination.file`) to `target` over `session`.
  See the moduledoc. `opts`: `:resume`, `:tag`, `:holds`, `:deadline`.
  """
  @spec put(Session.t(), Target.t(), map(), keyword()) ::
          :ok | {:ok, :already_present} | {:error, term()}
  def put(session, target, %{subdir: subdir, name: name} = file, opts) do
    with {:ok, dir} <- Files.ensure_dir(session, target, subdir) do
      sweep(session, dir, subdir)
      dest = dir <> "/" <> name

      case present(session, dest, file) do
        :present -> {:ok, :already_present}
        :absent -> send_file(session, dir, dest, file, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Removes the temporary file of a recorded upload: `checkpoint`'s token in
  `subdir` (`abort_upload/3`). Absent is `:ok`; a link is refused.
  """
  @spec abort(Session.t(), Target.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def abort(session, target, subdir, name, token) do
    partial = token_partial(name, token)

    with :ok <- Files.subdir_not_linked(session, target, subdir) do
      Files.delete(session, Target.file(target, subdir, partial), "#{subdir}/#{partial}")
    end
  end

  ## Already there

  defp present(session, dest, file) do
    case Files.lstat(session, dest, file.name) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == file.bytes ->
        same_content(session, dest, file)

      {:ok, %File.Stat{type: :regular}} ->
        :absent

      {:ok, %File.Stat{} = stat} ->
        not_a_file(stat, file)

      other ->
        other
    end
  end

  defp same_content(session, dest, file) do
    with {:ok, digest} <- Files.hash(session, dest, file.bytes, file.name) do
      if digest == String.downcase(to_string(file.sha256)), do: :present, else: :absent
    end
  end

  defp not_a_file(%File.Stat{type: :symlink}, file),
    do: {:error, Files.link("#{file.subdir}/#{file.name}")}

  defp not_a_file(_stat, file),
    do: {:error, {:permanent, "#{file.subdir}/#{file.name} on the server is not a regular file"}}

  ## Sending

  defp send_file(session, dir, dest, file, opts) do
    ctx = %{
      session: session,
      dir: dir,
      dest: dest,
      file: file,
      resume: Keyword.get(opts, :resume),
      holds: Keyword.get(opts, :holds, fn -> :ok end),
      deadline: Keyword.get(opts, :deadline)
    }

    case ctx.resume do
      %Resume{} -> resumable(ctx)
      _none -> plain(ctx, Artifact.partial_name(file.name, Keyword.get(opts, :tag)))
    end
  end

  defp plain(ctx, partial_name) do
    partial = ctx.dir <> "/" <> partial_name

    with :ok <- free(ctx, partial),
         {:ok, handle} <- Files.open(ctx.session, partial, [:write, :binary], partial_name) do
      ctx = Map.merge(ctx, %{partial: partial, token: nil, fresh?: true})

      case write(ctx, handle, 0) do
        :ok -> finish(ctx)
        {:error, :superseded} = superseded -> superseded
        {:error, _reason} = error -> discard(ctx, error)
      end
    end
  end

  # A path this call is about to write must not be a link or a folder.
  defp free(ctx, path) do
    case Files.lstat(ctx.session, path, Path.basename(path)) do
      :absent ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, Files.link(Path.basename(path))}

      {:ok, %File.Stat{}} ->
        {:error, {:permanent, "#{Path.basename(path)} on the server is not a regular file"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp resumable(ctx) do
    checkpoint = ctx.resume.checkpoint || %{}

    if token?(checkpoint["token"]),
      do: resume(ctx, checkpoint["token"], done(checkpoint)),
      else: fresh(ctx)
  end

  defp done(%{"bytes_done" => done}) when is_integer(done) and done >= 0, do: done
  defp done(_checkpoint), do: 0

  defp fresh(ctx) do
    token = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    partial = ctx.dir <> "/" <> token_partial(ctx.file.name, token)
    ctx = Map.merge(ctx, %{partial: partial, token: token, fresh?: true})

    with :ok <- save(ctx, 0),
         :absent <- taken(ctx, partial),
         {:ok, handle} <- Files.open(ctx.session, partial, [:write, :binary], partial_name(ctx)) do
      # Recorded under its token already, whatever stops it: `:deadline`,
      # an error, or `:superseded` (the attempt that took over may resume
      # this very file, as S3 leaves its multipart upload), so the file is
      # kept for the record to resume or abort.
      with :ok <- write(ctx, handle, 0), do: finish(ctx)
    end
  end

  defp taken(ctx, partial) do
    case Files.lstat(ctx.session, partial, partial_name(ctx)) do
      :absent -> :absent
      {:error, _reason} = error -> error
      {:ok, _stat} -> {:error, "#{partial_name(ctx)} already exists on the server"}
    end
  end

  defp resume(ctx, token, done) do
    partial = ctx.dir <> "/" <> token_partial(ctx.file.name, token)
    ctx = Map.merge(ctx, %{partial: partial, token: token, fresh?: false})

    case Files.lstat(ctx.session, partial, partial_name(ctx)) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= ctx.file.bytes ->
        from = div(Enum.min([size, done, ctx.file.bytes]), @resume_unit) * @resume_unit
        continue(ctx, from)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, Files.link(partial_name(ctx))}

      {:ok, %File.Stat{type: :regular}} ->
        restart(ctx)

      {:ok, %File.Stat{}} ->
        {:error, {:permanent, "#{partial_name(ctx)} on the server is not a regular file"}}

      :absent ->
        fresh(ctx)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue(ctx, from) do
    with {:ok, handle} <-
           Files.open(ctx.session, ctx.partial, [:read, :write, :binary], partial_name(ctx)) do
      ctx |> same_tail?(handle, from) |> go_on(ctx, handle, from)
    end
  end

  defp go_on(true, ctx, handle, from) do
    with :ok <- write(ctx, handle, from), do: finish(ctx)
  end

  defp go_on(false, ctx, handle, _from) do
    Session.sftp(ctx.session, :close, [handle])
    restart(ctx)
  end

  defp go_on({:error, _reason} = error, ctx, handle, _from) do
    Session.sftp(ctx.session, :close, [handle])
    error
  end

  # The last MiB before `from` reads back as the local file has it.
  defp same_tail?(_ctx, _handle, 0), do: true

  defp same_tail?(ctx, handle, from) do
    length = min(@resume_unit, from)
    at = from - length

    with {:ok, remote} <- Files.read_range(ctx.session, handle, at, length, partial_name(ctx)),
         {:ok, local} <- local_range(ctx.file.path, at, length) do
      remote == local
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp local_range(path, at, length) do
    case File.open(path, [:read, :binary, :raw], &:file.pread(&1, at, length)) do
      {:ok, {:ok, data}} -> {:ok, data}
      _other -> {:error, "couldn't read #{Path.basename(path)} on this server"}
    end
  end

  defp restart(ctx) do
    with :ok <- Files.remove(ctx.session, ctx.partial, partial_name(ctx)), do: fresh(ctx)
  end

  defp partial_name(ctx), do: Path.basename(ctx.partial)

  defp save(%{resume: %Resume{save: save}, token: token}, done) when is_binary(token),
    do: save.(%{"token" => token, "bytes_done" => done})

  defp save(_ctx, _done), do: :ok

  ## Writing

  # Up to `@window` writes in flight, each at most `Files.io_bytes/0`.
  # Progress saved is the start of the oldest write not yet acknowledged,
  # so a checkpoint never claims a byte the server hasn't confirmed.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(ctx, handle, from) do
    result =
      case File.open(ctx.file.path, [:read, :binary, :raw]) do
        {:ok, io} ->
          try do
            state = %{pos: from, inflight: %{}, saved: from, saved_at: now()}
            pump(ctx, handle, io, state)
          after
            File.close(io)
          end

        {:error, reason} ->
          {:error, "couldn't read #{ctx.file.name} on this server: #{inspect(reason)}"}
      end

    closed = Session.sftp(ctx.session, :close, [handle])

    case {result, closed} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, Errors.op(:write, "writing #{ctx.file.name}", reason)}
      {error, _closed} -> error
    end
  end

  defp pump(ctx, handle, io, state) do
    cond do
      state.pos >= ctx.file.bytes and state.inflight == %{} ->
        :ok

      state.pos >= ctx.file.bytes or map_size(state.inflight) >= @window ->
        with {:ok, state} <- await(ctx, state), do: pump(ctx, handle, io, state)

      near_deadline?(ctx) ->
        stop(ctx, state)

      true ->
        with {:ok, state} <- send_chunk(ctx, handle, io, state), do: pump(ctx, handle, io, state)
    end
  end

  defp send_chunk(ctx, handle, io, state) do
    length = min(Files.io_bytes(), ctx.file.bytes - state.pos)

    case :file.pread(io, state.pos, length) do
      {:ok, data} when byte_size(data) == length ->
        case :ssh_sftp.apwrite(ctx.session.channel, handle, state.pos, data) do
          {:async, id} ->
            {:ok,
             %{state | pos: state.pos + length, inflight: Map.put(state.inflight, id, state.pos)}}

          {:error, reason} ->
            {:error, Errors.op(:write, "writing #{ctx.file.name}", reason)}
        end

      _short_or_error ->
        {:error, "#{ctx.file.name} changed on this server while it was sent"}
    end
  end

  defp await(ctx, state) do
    receive do
      {:async_reply, id, reply} when is_map_key(state.inflight, id) ->
        state = %{state | inflight: Map.delete(state.inflight, id)}

        case reply do
          :ok -> checkpoint(ctx, state)
          {:error, reason} -> {:error, Errors.op(:write, "writing #{ctx.file.name}", reason)}
        end
    after
      Session.op_timeout(ctx.session) ->
        {:error, "writing #{ctx.file.name}: the server didn't answer in time"}
    end
  end

  defp acked(state) do
    case Map.values(state.inflight) do
      [] -> state.pos
      positions -> Enum.min(positions)
    end
  end

  defp checkpoint(ctx, state) do
    acked = acked(state)

    if acked - state.saved >= checkpoint_bytes() or now() - state.saved_at >= @checkpoint_ms do
      case save(ctx, acked) do
        :ok -> {:ok, %{state | saved: acked, saved_at: now()}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, state}
    end
  end

  # `config :kiln_cms, KilnCMS.Backups.Destination.Sftp.Upload,
  # checkpoint_bytes:` — tests only, to save progress within a small file.
  defp checkpoint_bytes do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:checkpoint_bytes, @checkpoint_bytes)
  end

  defp near_deadline?(%{deadline: nil}), do: false
  defp near_deadline?(%{deadline: deadline}), do: deadline - now() <= @stop_ms

  # Every write in flight acknowledged, the progress saved, then `:deadline`.
  defp stop(ctx, state) do
    with {:ok, state} <- drain(ctx, state),
         :ok <- save(ctx, acked(state)) do
      {:error, :deadline}
    end
  end

  defp drain(_ctx, %{inflight: inflight} = state) when inflight == %{}, do: {:ok, state}

  defp drain(ctx, state) do
    with {:ok, state} <- await(ctx, %{state | saved_at: now()}), do: drain(ctx, state)
  end

  ## Finishing

  defp finish(ctx) do
    with :ok <- whole(ctx),
         :ok <- ctx.holds.() do
      Files.rename(
        ctx.session,
        ctx.partial,
        ctx.dest,
        ctx.file.bytes,
        "#{ctx.file.subdir}/#{ctx.file.name}"
      )
    end
  end

  defp whole(ctx) do
    case Files.lstat(ctx.session, ctx.partial, partial_name(ctx)) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == ctx.file.bytes ->
        :ok

      {:ok, %File.Stat{type: :regular, size: size}} ->
        discard(
          ctx,
          {:error,
           "#{ctx.file.name}: the server holds #{size} of #{ctx.file.bytes} bytes; nothing was kept"}
        )

      {:ok, %File.Stat{}} ->
        {:error, Files.link(partial_name(ctx))}

      :absent ->
        {:error, "#{partial_name(ctx)} disappeared from the server"}

      {:error, _reason} = error ->
        error
    end
  end

  # A temporary file this call made is removed with its error.
  defp discard(ctx, error) do
    Files.remove(ctx.session, ctx.partial, partial_name(ctx))
    error
  end

  defp now, do: System.monotonic_time(:millisecond)

  ## Stale temporary files

  # A step's temporary files (`<name>.partial`, `<name>.<tag>.partial`) a
  # stopped node left, older than the grace. Never a token's: those are
  # recorded uploads, removed only through `abort_upload/3`. Best-effort.
  defp sweep(session, dir, subdir) do
    cutoff = DateTime.add(DateTime.utc_now(), -Retention.partial_grace_s(), :second)

    with {:ok, names} <- Files.names(session, dir, subdir) do
      for name <- names, step_partial?(name), do: remove_if_stale(session, dir, name, cutoff)
    end

    :ok
  end

  defp remove_if_stale(session, dir, name, cutoff) do
    with {:ok, %File.Stat{type: :regular, mtime: mtime}} <-
           Files.lstat(session, dir <> "/" <> name, name),
         %DateTime{} = at <- Files.mtime(mtime),
         :lt <- DateTime.compare(at, cutoff) do
      Files.remove(session, dir <> "/" <> name, name)
    end
  end

  @doc """
  Whether `name` is a step's temporary file of a backup file
  (`<name>.partial` or `<name>.<tag>.partial`), and not a resumable
  upload's `<name>.<token>.partial`.
  """
  @spec step_partial?(String.t()) :: boolean()
  def step_partial?(name) do
    case name |> String.split(".") |> Enum.reverse() do
      ["partial", tag | rest] when rest != [] ->
        stem = rest |> Enum.reverse() |> Enum.join(".")

        cond do
          token?(tag) -> false
          Artifact.tag?(tag) -> Destination.backup_file?(stem)
          true -> Destination.backup_file?(stem <> "." <> tag)
        end

      _other ->
        false
    end
  end
end
