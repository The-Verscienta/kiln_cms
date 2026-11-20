defmodule KilnCMS.Backups.Destination.Sftp.Files do
  @moduledoc """
  The file operations an SFTP destination is made of (#2222), on an open
  `KilnCMS.Backups.Destination.Sftp.Session`.

  ## Symbolic links

  The `db` and `media` subdirectories, a backup file and a temporary
  `.partial` must each be what they claim, never a symbolic link: a link
  there could make a listing, a delete or a write reach a file Kiln never
  put there. The operator's own base path is not checked: a NAS often routes
  its shares through links, and that path is theirs, not the form's.
  Every check is an `lstat`; a link found is refused, and the operation says
  so rather than following it.

  ## Message sizes

  Every write is at most 128 KiB, and every read asks for at most 128 KiB
  and loops on a short answer: OpenSSH's `sftp-server` ends the session on a
  message over 256 KiB and answers a read with at most about as much.
  """

  alias KilnCMS.Backups.Destination.RemotePath
  alias KilnCMS.Backups.Destination.Sftp.{Errors, Session, Target}

  @io_bytes 128 * 1024

  @doc "The largest single read or write sent, in bytes."
  @spec io_bytes() :: pos_integer()
  def io_bytes, do: @io_bytes

  @doc """
  What `path` is, without following a link: `{:ok, %File.Stat{}}`, `:absent`
  or `{:error, reason}`.
  """
  @spec lstat(Session.t(), String.t(), String.t()) ::
          {:ok, File.Stat.t()} | :absent | {:error, term()}
  def lstat(session, path, what) do
    case Session.sftp(session, :read_link_info, [String.to_charlist(path)]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, :no_such_file} -> :absent
      {:error, :no_such_path} -> :absent
      {:error, reason} -> {:error, Errors.op(:read, what, reason)}
    end
  end

  @doc """
  The base directory and `subdir` under it, created where missing. The
  base's own components are created but not inspected (see the moduledoc);
  `subdir` must be a directory, never a link.
  """
  @spec ensure_dir(Session.t(), Target.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_dir(session, target, subdir) do
    with :ok <- ensure_base(session, target) do
      dir = Target.dir(target, subdir)

      case lstat(session, dir, subdir) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, dir}
        {:ok, %File.Stat{type: :symlink}} -> {:error, link(subdir)}
        {:ok, %File.Stat{}} -> {:error, {:permanent, "#{subdir} on the server is not a folder"}}
        :absent -> make_dir(session, dir, subdir)
        {:error, _reason} = error -> error
      end
    end
  end

  defp ensure_base(session, target) do
    target
    |> Target.base_prefixes()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case base_dir(session, dir) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Followed, not `lstat`ed: the operator's own path may run through links.
  defp base_dir(session, dir) do
    case Session.sftp(session, :read_file_info, [String.to_charlist(dir)]) do
      {:ok, _info} ->
        :ok

      {:error, reason} when reason in [:no_such_file, :no_such_path] ->
        with {:ok, _dir} <- make_dir(session, dir, "the path"), do: :ok

      {:error, reason} ->
        {:error, Errors.op(:read, "reading the path", reason)}
    end
  end

  defp make_dir(session, dir, what) do
    case Session.sftp(session, :make_dir, [String.to_charlist(dir)]) do
      :ok ->
        {:ok, dir}

      {:error, reason} ->
        # Another call may have made it meanwhile.
        case Session.sftp(session, :read_file_info, [String.to_charlist(dir)]) do
          {:ok, _info} -> {:ok, dir}
          _missing -> {:error, Errors.op(:change, "creating #{what}", reason)}
        end
    end
  end

  @doc """
  The whole backup files in `subdir`: regular files only, with names a
  listing may answer (`RemotePath.listed_name?/1`). A missing subdirectory
  is none; a linked one is refused.
  """
  @spec list(Session.t(), Target.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(session, target, subdir) do
    dir = Target.dir(target, subdir)

    case lstat(session, dir, subdir) do
      :absent -> {:ok, []}
      {:ok, %File.Stat{type: :directory}} -> entries(session, dir, subdir)
      {:ok, %File.Stat{type: :symlink}} -> {:error, link(subdir)}
      {:ok, %File.Stat{}} -> {:error, {:permanent, "#{subdir} on the server is not a folder"}}
      {:error, _reason} = error -> error
    end
  end

  defp entries(session, dir, subdir) do
    with {:ok, names} <- names(session, dir, subdir) do
      names
      |> Enum.filter(&RemotePath.listed_name?/1)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, &entry_into(session, dir, subdir, &1, &2))
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  @doc "The names in `dir` (as strings), or `{:error, reason}`."
  @spec names(Session.t(), String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def names(session, dir, subdir) do
    case Session.sftp(session, :list_dir, [String.to_charlist(dir)]) do
      {:ok, names} -> {:ok, Enum.map(names, &to_string/1)}
      {:error, reason} -> {:error, Errors.op(:read, "listing #{subdir}", reason)}
    end
  end

  # A regular file only: a link or a file gone meanwhile is left out.
  defp entry_into(session, dir, subdir, name, {:ok, acc}) do
    case lstat(session, dir <> "/" <> name, "#{subdir}/#{name}") do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:cont, {:ok, [entry(subdir, name, stat) | acc]}}

      {:error, _reason} = error ->
        {:halt, error}

      _link_or_gone ->
        {:cont, {:ok, acc}}
    end
  end

  defp entry(subdir, name, stat),
    do: %{subdir: subdir, name: name, bytes: stat.size, mtime: mtime(stat.mtime)}

  @doc "An SFTP mtime (local time, as OTP gives it) as a UTC `DateTime`."
  @spec mtime(:calendar.datetime() | term()) :: DateTime.t() | nil
  def mtime({{_y, _m, _d}, {_h, _i, _s}} = local) do
    case :calendar.local_time_to_universal_time_dst(local) do
      [utc | _] -> utc |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
      [] -> nil
    end
  rescue
    _error -> nil
  end

  def mtime(_other), do: nil

  @doc """
  `path`, a regular file (never a link), read whole into the local file
  `to` and hashed: `{:ok, sha256_hex}`.
  """
  @spec download(Session.t(), String.t(), Path.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def download(session, path, to, what) do
    with {:ok, size} <- regular_size(session, path, what),
         {:ok, io} <- open_local(to) do
      result =
        try do
          read_all(session, path, size, what, fn data -> IO.binwrite(io, data) end)
        after
          File.close(io)
        end

      with {:error, _reason} = error <- result do
        File.rm(to)
        error
      end
    end
  end

  # `to` is the core caller's own local path; nothing of the server's names it.
  # sobelow_skip ["Traversal.FileModule"]
  defp open_local(to) do
    case File.open(to, [:write, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, "couldn't write #{to}: #{inspect(reason)}"}
    end
  end

  @doc """
  The sha256 of `path`, a regular file of `size` bytes, read in full.
  """
  @spec hash(Session.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def hash(session, path, size, what), do: read_all(session, path, size, what, fn _ -> :ok end)

  defp regular_size(session, path, what) do
    case lstat(session, path, what) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: :symlink}} -> {:error, link(what)}
      {:ok, %File.Stat{}} -> {:error, "#{what} on the server is not a regular file"}
      :absent -> {:error, "#{what} is not on the server"}
      {:error, _reason} = error -> error
    end
  end

  defp read_all(session, path, size, what, sink) do
    with {:ok, handle} <- open(session, path, [:read, :binary], what) do
      try do
        read_loop(session, handle, 0, size, :crypto.hash_init(:sha256), what, sink)
      after
        Session.sftp(session, :close, [handle])
      end
    end
  end

  defp read_loop(session, handle, at, size, sha, what, sink) when at < size do
    case read_range(session, handle, at, min(@io_bytes, size - at), what) do
      {:ok, data} ->
        with :ok <- sink.(data),
             do:
               read_loop(
                 session,
                 handle,
                 at + byte_size(data),
                 size,
                 :crypto.hash_update(sha, data),
                 what,
                 sink
               )

      {:error, _reason} = error ->
        error
    end
  end

  defp read_loop(session, handle, size, size, sha, what, _sink) do
    # Nothing past the size it had: a file still growing is not this one.
    case Session.sftp(session, :pread, [handle, size, 1]) do
      :eof -> {:ok, sha |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:ok, _more} -> {:error, "#{what} grew while it was read"}
      {:error, reason} -> {:error, Errors.op(:read, "reading #{what}", reason)}
    end
  end

  @doc """
  Exactly `length` bytes of `handle` from `at`, looping on short reads (at
  most `io_bytes/0` asked at once). A file that ends first is an error.
  """
  @spec read_range(Session.t(), term(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_range(session, handle, at, length, what),
    do: read_range(session, handle, at, length, what, [])

  defp read_range(_session, _handle, _at, 0, _what, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_range(session, handle, at, length, what, acc) do
    case Session.sftp(session, :pread, [handle, at, min(length, @io_bytes)]) do
      {:ok, data} when byte_size(data) > 0 and byte_size(data) <= length ->
        read_range(session, handle, at + byte_size(data), length - byte_size(data), what, [
          data | acc
        ])

      {:ok, _data} ->
        {:error, "#{what}: the server sent a different part of the file than was asked for"}

      :eof ->
        {:error, "#{what} is shorter than the server said"}

      {:error, reason} ->
        {:error, Errors.op(:read, "reading #{what}", reason)}
    end
  end

  @doc "Opens `path` with OTP's `modes`."
  @spec open(Session.t(), String.t(), [atom()], String.t()) :: {:ok, term()} | {:error, term()}
  def open(session, path, modes, what) do
    op = if :write in modes, do: :write, else: :read

    case Session.sftp(session, :open, [String.to_charlist(path), modes]) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, Errors.op(op, "opening #{what}", reason)}
    end
  end

  @doc """
  Removes `path`: a regular file, never a link (refused) or anything else.
  A file already gone is `:ok`.
  """
  @spec delete(Session.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(session, path, what) do
    case lstat(session, path, what) do
      {:ok, %File.Stat{type: :regular}} ->
        remove(session, path, what)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, link(what)}

      {:ok, %File.Stat{}} ->
        {:error, "#{what} on the server is not a regular file; it was left alone"}

      :absent ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Removes `path` with no check: a path this call made itself."
  @spec remove(Session.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove(session, path, what) do
    case Session.sftp(session, :delete, [String.to_charlist(path)]) do
      :ok -> :ok
      {:error, reason} when reason in [:no_such_file, :no_such_path] -> :ok
      {:error, reason} -> {:error, Errors.op(:change, "deleting #{what}", reason)}
    end
  end

  @doc """
  Moves `from`, a file of `bytes` bytes, over `to`. A server with
  `posix-rename@openssh.com` (OpenSSH) replaces `to` in one step, which OTP
  uses when it is offered; one without refuses an existing `to`. `to` is
  then removed (a regular file only) and the rename made again, but only
  once `from` is checked to be still there, a regular file of `bytes`:
  a refusal for any other reason (`from` gone or replaced) never costs the
  file already in place.
  """
  @spec rename(Session.t(), String.t(), String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, term()}
  def rename(session, from, to, bytes, what) do
    case Session.sftp(session, :rename, [String.to_charlist(from), String.to_charlist(to)]) do
      :ok ->
        :ok

      {:error, reason} when reason in [:file_already_exists, :failure] ->
        with :ok <- still_whole(session, from, bytes, what, reason),
             :ok <- delete(session, to, what),
             do: rename_again(session, from, to, what)

      {:error, reason} ->
        {:error, Errors.op(:change, "moving #{what} into place", reason)}
    end
  end

  defp still_whole(session, from, bytes, what, reason) do
    case lstat(session, from, what) do
      {:ok, %File.Stat{type: :regular, size: ^bytes}} -> :ok
      {:error, _reason} = error -> error
      _gone_or_changed -> {:error, Errors.op(:change, "moving #{what} into place", reason)}
    end
  end

  defp rename_again(session, from, to, what) do
    case Session.sftp(session, :rename, [String.to_charlist(from), String.to_charlist(to)]) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.op(:change, "moving #{what} into place", reason)}
    end
  end

  @doc """
  `:ok` unless `subdir` is a symbolic link (refused): checked before a file
  in it is read, deleted or aborted. A missing subdirectory passes, and the
  file's own check answers for it.
  """
  @spec subdir_not_linked(Session.t(), Target.t(), String.t()) :: :ok | {:error, term()}
  def subdir_not_linked(session, target, subdir) do
    case lstat(session, Target.dir(target, subdir), subdir) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, link(subdir)}
      {:error, _reason} = error -> error
      _dir_or_absent -> :ok
    end
  end

  @doc "The refusal of a symbolic link where a file or folder of Kiln's must be."
  @spec link(String.t()) :: {:permanent, String.t()}
  def link(what),
    do: {:permanent, "#{what} on the server is a symbolic link; Kiln doesn't follow links there"}
end
