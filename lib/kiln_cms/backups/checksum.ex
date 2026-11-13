defmodule KilnCMS.Backups.Checksum do
  @moduledoc """
  SHA-256 of backup files, in bounded memory (#2218).

  A media archive can be many gigabytes, so nothing here reads a file whole:
  `file/1` and `concat/1` stream it through `:crypto.hash_update/2` in 1 MiB
  chunks with raw file I/O, and never shell out to `sha256sum` (whose name and
  flags differ between GNU and macOS, and whose output would be one more thing
  to parse).

  `concat/1` hashes a list of files in one pass and returns both each file's
  digest and the digest of their bytes concatenated in order, which is what
  `cat part01 part02 … | sha256sum` prints and what a multi-part artifact
  records as its own `sha256`.

  ## Sidecars

  A checksum recorded only in the manifest is lost with the manifest: the next
  run replaces it, and an operator restoring from a bare directory never had
  it. So each artifact also gets a sidecar next to its files
  (`kiln-media-<stamp>.sha256`), in the format `sha256sum -c` reads, one
  `<hex>  <filename>` line per file in part order:

      3b1f…  kiln-media-20260805-031700.part01.tar.gz
      9ac0…  kiln-media-20260805-031700.part02.tar.gz

  `write_sidecar/2` writes it (mode 0600, atomically); `parse_sidecar/1` reads
  one back. Names in a sidecar are file names only, never paths.
  """

  @chunk 1_048_576

  @type hex :: String.t()

  @doc """
  The SHA-256 (lowercase hex) and byte count of the file at `path`.

  Memory is bounded by the chunk size, whatever the file's.
  """
  @spec file(Path.t()) :: {:ok, hex(), non_neg_integer()} | {:error, term()}
  def file(path) do
    with {:ok, %{sha256: hex, bytes: bytes}} <- concat([path]), do: {:ok, hex, bytes}
  end

  @doc """
  Hash `paths` in one pass, in the order given.

  Returns each file's digest and size, plus the digest and size of all their
  bytes concatenated in that order. An unreadable file fails the whole call
  with its error; an empty list is an error too (the digest of nothing would
  read as a checksum).
  """
  @spec concat([Path.t()]) ::
          {:ok,
           %{
             files: [%{path: Path.t(), sha256: hex(), bytes: non_neg_integer()}],
             sha256: hex(),
             bytes: non_neg_integer()
           }}
          | {:error, term()}
  def concat([]), do: {:error, :no_files}

  def concat(paths) when is_list(paths) do
    total = :crypto.hash_init(:sha256)

    paths
    |> Enum.reduce_while({:ok, total, []}, fn path, {:ok, total, acc} ->
      case hash_file(path, total) do
        {:ok, total, hex, bytes} ->
          {:cont, {:ok, total, [%{path: path, sha256: hex, bytes: bytes} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, total, acc} ->
        files = Enum.reverse(acc)

        {:ok,
         %{
           files: files,
           sha256: total |> :crypto.hash_final() |> hex(),
           bytes: files |> Enum.map(& &1.bytes) |> Enum.sum()
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Whether the file at `path` hashes to `expected` (hex, either case).

  `:ok`, `{:error, :mismatch}`, or the read error. The comparison is constant
  time, so a digest can't be probed byte by byte through response timing if one
  is ever checked on behalf of a request.
  """
  @spec verify(Path.t(), hex() | term()) :: :ok | {:error, :mismatch | term()}
  def verify(path, expected) when is_binary(expected) do
    with {:ok, actual, _bytes} <- file(path) do
      if Plug.Crypto.secure_compare(actual, String.downcase(expected)),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  def verify(_path, _expected), do: {:error, :mismatch}

  @doc """
  Re-hash the file at `path` and say whether it is still the file a backup
  verified (#2218): a regular file (not followed through a symlink) of
  `expected_bytes` (when given) whose SHA-256 is `expected` (hex, either case).

  `KilnCMS.Backups.Steps` calls this in two places: immediately before each
  off-site copy of a dump or media part (a sidecar goes through
  `check_sidecar/2` instead), with the digest it recorded when the file was written, so a
  file changed on disk in between is refused rather than uploaded; and before a
  resume or retry reuses a dump or media part, so only a file that still
  matches its recorded digest is reused.

  Returns `:ok`, or `{:error, reason}`: `:no_digest` (nothing on record to
  compare with, so nothing can be vouched for), `:not_regular`,
  `{:changed, %{expected, actual, expected_bytes, bytes}}`, or the read error
  (`:enoent`, …). Not built on `verify/2`, which answers only yes or no: a
  refusal has to say what was found (digest and size) and why (file type).
  The digest comparison is constant time, as in `verify/2`.
  """
  @spec recheck(Path.t(), hex() | nil, non_neg_integer() | nil) ::
          :ok
          | {:error,
             :no_digest
             | :not_regular
             | {:changed,
                %{
                  expected: hex(),
                  actual: hex(),
                  expected_bytes: non_neg_integer() | nil,
                  bytes: non_neg_integer()
                }}
             | term()}
  # sobelow_skip ["Traversal.FileModule"]
  def recheck(path, expected, expected_bytes) when is_binary(expected) do
    expected = String.downcase(expected)

    with :ok <- regular(path),
         {:ok, actual, bytes} <- file(path) do
      if Plug.Crypto.secure_compare(actual, expected) and
           (is_nil(expected_bytes) or bytes == expected_bytes) do
        :ok
      else
        {:error,
         {:changed,
          %{expected: expected, actual: actual, expected_bytes: expected_bytes, bytes: bytes}}}
      end
    end
  end

  def recheck(_path, _expected, _expected_bytes), do: {:error, :no_digest}

  @doc """
  Check that the sidecar at `path` still says exactly `entries`, a list of
  `{file_name, hex}` in part order (#2218): the same lines, in the same order,
  and nothing else. Like `recheck/3`, it runs immediately before the sidecar's
  off-site copy.

  This compares the PARSED sidecar with what the backup recorded, where
  `scripts/backup.sh` hashes the sidecar's bytes; both catch a sidecar changed
  after it was written (the parse ignores only a `sha256sum` binary-mode `*`).

  `:ok`, or `{:error, reason}`: `:no_digest` (an entry with no digest on
  record), `:not_regular`, `:malformed`, `:sidecar_changed`, or the read error.
  """
  @spec check_sidecar(Path.t(), [{String.t(), hex() | nil}]) :: :ok | {:error, term()}
  def check_sidecar(path, entries) when is_list(entries) do
    with :ok <- recorded(entries),
         :ok <- regular(path),
         {:ok, found} <- parse_sidecar(path) do
      if same_entries?(found, entries), do: :ok, else: {:error, :sidecar_changed}
    end
  end

  defp recorded(entries) do
    if entries != [] and Enum.all?(entries, &match?({_name, hex} when is_binary(hex), &1)),
      do: :ok,
      else: {:error, :no_digest}
  end

  defp same_entries?(found, entries) do
    length(found) == length(entries) and
      found
      |> Enum.zip(entries)
      |> Enum.all?(fn {{hex, name}, {expected_name, expected_hex}} ->
        name == expected_name and Plug.Crypto.secure_compare(hex, String.downcase(expected_hex))
      end)
  end

  # `lstat`, so a symlink swapped in for a backup file is refused rather than
  # followed to whatever it points at.
  # sobelow_skip ["Traversal.FileModule"]
  defp regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _other} -> {:error, :not_regular}
      {:error, _} = error -> error
    end
  end

  # One file, folded into the running whole-set hash as well.
  defp hash_file(path, total) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          read_loop(io, :crypto.hash_init(:sha256), total, 0)
        after
          :file.close(io)
        end

      {:error, _} = error ->
        error
    end
  end

  defp read_loop(io, one, total, bytes) do
    case :file.read(io, @chunk) do
      {:ok, data} ->
        read_loop(
          io,
          :crypto.hash_update(one, data),
          :crypto.hash_update(total, data),
          bytes + byte_size(data)
        )

      :eof ->
        {:ok, total, one |> :crypto.hash_final() |> hex(), bytes}

      {:error, _} = error ->
        error
    end
  end

  defp hex(digest), do: Base.encode16(digest, case: :lower)

  @doc """
  Write a `sha256sum -c` sidecar at `path` for `entries`, a list of
  `{file_name, hex}` in the order the files should be checked.

  Atomic (written beside, then renamed) and mode 0600. File names must be bare
  names: anything with a path separator, a newline, or that is empty is
  `{:error, :invalid_name}`, because a sidecar line is `hex  name` and a name
  containing a newline would forge a second line.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_sidecar(Path.t(), [{String.t(), hex()}]) :: :ok | {:error, term()}
  def write_sidecar(path, [_ | _] = entries) when is_binary(path) do
    tmp = path <> ".partial"

    with :ok <- validate(entries),
         :ok <-
           File.write(
             tmp,
             Enum.map_join(entries, fn {name, hex} -> "#{String.downcase(hex)}  #{name}\n" end)
           ),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  def write_sidecar(_path, _entries), do: {:error, :invalid_name}

  defp validate(entries) do
    if Enum.all?(entries, &valid_entry?/1), do: :ok, else: {:error, :invalid_name}
  end

  defp valid_entry?({name, hex}) when is_binary(name) and is_binary(hex),
    do: bare_name?(name) and hex =~ ~r/\A[0-9a-fA-F]{64}\z/

  defp valid_entry?(_other), do: false

  defp bare_name?(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, ["/", "\\", "\n", "\r", "\0"])

  @doc """
  Parse the sidecar at `path` into `{:ok, [{hex, file_name}]}` in file order.

  Reads what `sha256sum` writes too (a `*` before the name marks binary mode).
  Strict: a malformed line, an uppercase-or-short digest, a name with a path in
  it, or an empty file is `{:error, :malformed}`, never a partial list.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec parse_sidecar(Path.t()) :: {:ok, [{hex(), String.t()}]} | {:error, term()}
  def parse_sidecar(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path), do: parse_sidecar_contents(contents)
  end

  @doc "As `parse_sidecar/1`, for text already in memory."
  @spec parse_sidecar_contents(binary()) :: {:ok, [{hex(), String.t()}]} | {:error, :malformed}
  def parse_sidecar_contents(contents) when is_binary(contents) do
    lines = contents |> String.split("\n") |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(lines, &parse_line/1)

    if parsed == [] or :error in parsed, do: {:error, :malformed}, else: {:ok, parsed}
  end

  defp parse_line(line) do
    with [_, hex, name] <- Regex.run(~r/\A([0-9a-f]{64})  ?\*?(.+)\z/, line),
         true <- bare_name?(name) do
      {hex, name}
    else
      _ -> :error
    end
  end
end
