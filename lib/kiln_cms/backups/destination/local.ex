defmodule KilnCMS.Backups.Destination.Local do
  @moduledoc """
  A backup destination that is a directory on this host (#2220): a NAS mount,
  a second disk, a volume something else ships elsewhere.

  Only under a directory the operator lists in
  `BACKUP_LOCAL_DESTINATION_ROOTS` (decision E6). With none listed, Local is
  not offered (`available?/0`) and every call refuses. A platform admin picks
  the directory in the console, so the rules below are what stops that form
  from writing a database dump somewhere the app serves, or over the files it
  backs up:

    * absolute, with no `..` segment and no control character;
    * inside one of the roots, or a root itself;
    * no component of it, from `/` down, is a symbolic link (an `lstat`
      walk), so nothing can point it somewhere else;
    * not inside, equal to, or an ancestor of `BACKUP_DIR`, `MEDIA_DIR`,
      `priv/static` or either uploads directory, compared both as written and
      with their own symbolic links resolved.

  Every call checks them again, on the node that runs it (critic change 6):
  a root unmounted since the destination was saved, or a symlink put in its
  path, refuses the call rather than following it.

  A file is copied to `<name>.partial` (directories 0700, files 0600, as the
  backup directory itself), re-hashed and checked against the sha256 it
  verified with, and only then renamed into place. A copy that does not match
  is removed: nothing lands unverified. `list/1` and `delete/2` touch regular
  files only.

  The off-site step passes two options of the core's own, never given to a
  plugin's adapter (#3041, ADR 0067): `:tag`, its job and attempt, so the
  temporary file is `<name>.<job>-<attempt>.partial`
  (`KilnCMS.Backups.Artifact.partial_name/2`) and no two steps share one; and
  `:rename`, the rename into place under the step's lease
  (`KilnCMS.Backups.Chain.fenced_rename/3`). A step that outlived its Cancel
  then never replaces the file the resumed backup put there: its rename is
  refused with `{:error, :superseded}` and it removes its own temporary file.
  Without them (a call made outside a step) the file is `<name>.partial` and
  the rename is a plain one, as before. A temporary file left by a node that
  stopped mid-copy is removed by any later put to the destination once it is
  older than `KilnCMS.Backups.Retention.partial_grace_s/0`; the file in place
  is given its source's mtime only after the rename, so a copy waiting for
  its rename never looks that old.

  A file already in place with the same size and sha256 is not copied again:
  `put/3` answers `{:ok, :already_present}` (#2223). The size is compared
  first; only a file of the right size is read whole to hash it.
  """

  use Kiln.BackupDestination

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Checksum, Destination, Retention}

  @subdirs ["db", "media"]
  @test_dir ".kiln-test"
  @max_links 40

  @impl Kiln.BackupDestination
  def kind, do: "local"

  @impl Kiln.BackupDestination
  def label, do: "Directory on this server"

  @impl Kiln.BackupDestination
  def fields do
    [
      %{
        name: "path",
        type: :string,
        required?: true,
        help: "An absolute directory under one of BACKUP_LOCAL_DESTINATION_ROOTS."
      }
    ]
  end

  @impl Kiln.BackupDestination
  def supports, do: [:list, :delete]

  @doc """
  Whether Local destinations can be used: `BACKUP_LOCAL_DESTINATION_ROOTS`
  lists at least one directory.
  """
  @spec available?() :: boolean()
  def available?, do: roots() != []

  @doc "The directories a Local destination may be in, expanded."
  @spec roots() :: [Path.t()]
  def roots do
    :kiln_cms
    |> Application.get_env(Backups, [])
    |> Keyword.get(:local_destination_roots, [])
    |> Enum.map(&Path.expand/1)
  end

  @doc """
  Parses `BACKUP_LOCAL_DESTINATION_ROOTS`: absolute directories separated by
  commas, blanks ignored. `:error` when any entry is not absolute or has a
  `..` segment, so one typo can't widen where backups may be written.
  """
  @spec parse_roots(String.t()) :: {:ok, [Path.t()]} | :error
  def parse_roots(raw) when is_binary(raw) do
    entries = raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if Enum.all?(entries, &usable_root?/1),
      do: {:ok, Enum.map(entries, &Path.expand/1)},
      else: :error
  end

  defp usable_root?(entry),
    do: Path.type(entry) == :absolute and ".." not in Path.split(entry)

  @impl Kiln.BackupDestination
  def validate(config) do
    with {:ok, _dir} <- checked(config), do: :ok
  end

  # The probe is a random name under `checked/1`'s directory, whose root,
  # symlink-free walk and app-directory exclusions were just verified.
  # sobelow_skip ["Traversal.FileModule"]
  @impl Kiln.BackupDestination
  def test(config) do
    with {:ok, dir} <- checked(config),
         {:ok, probe_dir} <- ensure_dir(dir, @test_dir) do
      hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      file = Path.join(probe_dir, "kiln-test-#{hex}.txt")
      body = "Kiln backup destination test #{hex}\n"

      try do
        with :ok <- write_private(file, body),
             {:ok, ^body} <- File.read(file) do
          :ok
        else
          {:ok, _other} -> {:error, "the test file read back differs from what was written"}
          {:error, reason} -> {:error, "couldn't write a test file in #{dir}: #{format(reason)}"}
        end
      after
        File.rm(file)
        File.rmdir(probe_dir)
      end
    end
  end

  # `target` is a `safe_ref/2` basename under `ensure_dir/2`'s verified
  # directory; `source` is the backup step's own file, not admin input.
  # sobelow_skip ["Traversal.FileModule"]
  @impl Kiln.BackupDestination
  def put(config, %{path: source, subdir: subdir, name: name} = file, opts) do
    with {:ok, dir} <- checked(config),
         :ok <- safe_ref(subdir, name),
         {:ok, target_dir} <- ensure_dir(dir, subdir) do
      target = Path.join(target_dir, name)
      partial = Artifact.partial_name(target, Keyword.get(opts, :tag))
      rename = Keyword.get(opts, :rename, &File.rename/2)

      sweep_stale_partials(dir)

      if present?(target, file),
        do: {:ok, :already_present},
        else: copy_in(source, {partial, target, rename}, file)
    end
  end

  # The temporary files a copy left behind when its node stopped mid-copy:
  # each attempt has a name of its own, so a later one neither reuses nor
  # clears them, and once a later attempt lands the file nothing else would.
  # Every put sweeps `db/` and `media/` for them, as the backup directory's
  # own partial sweep does (#3041): a backup file's `<name>.partial` or
  # `<name>.<tag>.partial`, removed once its mtime is older than
  # `Retention.partial_grace_s/0`. A copy under way keeps its file: writing
  # it moves its mtime on, and `place/3` touches it again just before its
  # rename. Best-effort.
  # `dir` is `checked/1`'s verified directory; only regular files whose names
  # are a backup file's temporary name are removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_stale_partials(dir) do
    cutoff = System.os_time(:second) - Retention.partial_grace_s()

    for subdir <- @subdirs,
        sub = Path.join(dir, subdir),
        {:ok, names} <- [File.ls(sub)],
        name <- names,
        backup_partial?(name),
        path = Path.join(sub, name),
        {:ok, %File.Stat{type: :regular, mtime: mtime}} <- [File.lstat(path, time: :posix)],
        mtime < cutoff,
        do: File.rm(path)

    :ok
  end

  # `<name>.partial`, or `<name>.<tag>.partial` for a tag a step writes, of
  # a backup file's `name`.
  defp backup_partial?(name) do
    case String.split(name, ".") |> Enum.reverse() do
      ["partial", tag | rest] when rest != [] ->
        stem = rest |> Enum.reverse() |> Enum.join(".")

        Destination.backup_file?(stem <> "." <> tag) or
          (Artifact.tag?(tag) and Destination.backup_file?(stem))

      _other ->
        false
    end
  end

  # `partial` and `target` are `put/3`'s verified paths. The temporary file
  # is this call's own, so it is removed on any error, a refused rename
  # included.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_in(source, {partial, _target, _rename} = paths, file) do
    with {:error, _reason} = error <- place(source, paths, file) do
      File.rm(partial)
      error
    end
  end

  # The very file is already there: a regular file of the same size, then
  # the same sha256 (read whole, only once the size matched).
  # `target` is `put/3`'s verified target.
  # sobelow_skip ["Traversal.FileModule"]
  defp present?(target, file) do
    with bytes when is_integer(bytes) <- file[:bytes],
         sha256 when is_binary(sha256) <- file[:sha256],
         {:ok, %File.Stat{type: :regular, size: ^bytes}} <- File.lstat(target),
         {:ok, digest, ^bytes} <- Checksum.file(target) do
      digest == String.downcase(sha256)
    else
      _ -> false
    end
  end

  @impl Kiln.BackupDestination
  def list(config) do
    with {:ok, dir} <- checked(config) do
      {:ok, Enum.flat_map(@subdirs, &entries(dir, &1))}
    end
  end

  # `source` is a `safe_ref/2` basename under `checked/1`'s verified directory,
  # lstat'ed as a regular file; `to` is the core caller's own local path.
  # sobelow_skip ["Traversal.FileModule"]
  @impl Kiln.BackupDestination
  def get(config, %{subdir: subdir, name: name}, to) do
    with {:ok, dir} <- checked(config),
         :ok <- safe_ref(subdir, name) do
      source = Path.join([dir, subdir, name])

      with {:ok, %File.Stat{type: :regular}} <- File.lstat(source),
           {:ok, _bytes} <- File.copy(source, to) do
        :ok
      else
        {:ok, %File.Stat{}} -> {:error, "#{source} is not a regular file"}
        {:error, reason} -> {:error, "couldn't copy #{source}: #{format(reason)}"}
      end
    end
  end

  @impl Kiln.BackupDestination
  def delete(config, %{subdir: subdir, name: name}) do
    with {:ok, dir} <- checked(config),
         :ok <- safe_ref(subdir, name) do
      target = Path.join([dir, subdir, name])

      case File.lstat(target) do
        {:ok, %File.Stat{type: :regular}} -> rm(target)
        {:ok, _other} -> {:error, "#{target} is not a regular file; it was left alone"}
        {:error, :enoent} -> :ok
        {:error, :enotdir} -> :ok
        {:error, reason} -> {:error, "couldn't read #{target}: #{format(reason)}"}
      end
    end
  end

  @impl Kiln.BackupDestination
  def describe(%Config{settings: settings}), do: to_string(Map.get(settings, "path", ""))

  @doc """
  Where `config` writes, as `KilnCMS.Backups.Destination.overlap?/2`
  compares it: `{:local, segments}` of its expanded path.
  """
  @spec location(Config.t()) :: {:local, [String.t()]}
  def location(%Config{settings: settings}) do
    {:local, settings |> Map.get("path", "") |> to_string() |> Path.expand() |> segments()}
  end

  ## Path rules

  # The destination's directory when every rule holds, else an error naming
  # the first that doesn't. Checked again on every call.
  defp checked(%Config{settings: settings}) do
    with {:ok, roots} <- configured_roots(),
         {:ok, path} <- path_setting(settings),
         {:ok, root} <- under_root(path, roots),
         :ok <- no_symlinks(path, root),
         :ok <- clear_of_app_dirs(path) do
      {:ok, path}
    end
  end

  defp configured_roots do
    case roots() do
      [] -> {:error, "Local destinations are off: BACKUP_LOCAL_DESTINATION_ROOTS is not set"}
      roots -> {:ok, roots}
    end
  end

  defp path_setting(%{"path" => path}) when is_binary(path) do
    cond do
      Path.type(path) != :absolute -> {:error, "the path must be absolute"}
      ".." in Path.split(path) -> {:error, "the path must not contain .."}
      path =~ ~r/[\x00-\x1f\x7f]/ -> {:error, "the path must not contain control characters"}
      true -> {:ok, Path.expand(path)}
    end
  end

  defp path_setting(_settings), do: {:error, "the path is missing"}

  defp under_root(path, roots) do
    case Enum.find(roots, &within?(path, &1)) do
      nil ->
        {:error,
         "#{path} is not under BACKUP_LOCAL_DESTINATION_ROOTS (#{Enum.join(roots, ", ")})"}

      root ->
        {:ok, root}
    end
  end

  # Every component from `/` down is a real directory, not a link. The root
  # must exist; below it, the first missing component ends the walk (`put/3`
  # creates the rest, 0700, and checks again).
  defp no_symlinks(path, root) do
    path
    |> prefixes()
    |> Enum.reduce_while(:ok, fn prefix, :ok -> walk(prefix, root) end)
  end

  defp walk(prefix, root) do
    case File.lstat(prefix) do
      {:ok, %File.Stat{type: :directory}} ->
        {:cont, :ok}

      {:ok, %File.Stat{type: :symlink}} ->
        {:halt, {:error, "#{prefix} is a symbolic link; a destination's path must have none"}}

      {:ok, %File.Stat{}} ->
        {:halt, {:error, "#{prefix} is not a directory"}}

      {:error, :enoent} ->
        if within?(prefix, root) and prefix != root,
          do: {:halt, :ok},
          else: {:halt, {:error, "#{prefix} does not exist on this server"}}

      {:error, reason} ->
        {:halt, {:error, "couldn't read #{prefix}: #{format(reason)}"}}
    end
  end

  defp clear_of_app_dirs(path) do
    Enum.find_value(app_dirs(), :ok, fn {label, dir} ->
      forms = Enum.uniq([Path.expand(dir), real(dir)])

      if Enum.any?(forms, &(within?(path, &1) or within?(&1, path))),
        do: {:error, "#{path} overlaps #{label} (#{dir}); choose a directory outside it"}
    end)
  end

  # What a destination must stay clear of: the backups it copies, the files
  # they are taken from, and what the app serves.
  defp app_dirs do
    [
      {"BACKUP_DIR", Backups.dir()},
      {"MEDIA_DIR", Backups.media_dir()},
      {"priv/static", Application.app_dir(:kiln_cms, "priv/static")},
      {"the uploads directory", KilnCMS.Storage.Local.root()},
      {"the private uploads directory", KilnCMS.Storage.Local.private_root()}
    ]
    |> Enum.filter(fn {_label, dir} -> is_binary(dir) and dir != "" end)
  end

  ## Files

  # `subdir` under the destination, created 0700 where missing, then walked
  # again so a link put in place meanwhile is refused rather than followed.
  defp ensure_dir(dir, subdir) do
    target = Path.join(dir, subdir)

    with :ok <- created(mkdir_private(dir), dir),
         :ok <- created(mkdir_private(target), target),
         :ok <- no_symlinks(target, target) do
      {:ok, target}
    end
  end

  defp created(:ok, _dir), do: :ok
  defp created({:error, reason}, dir), do: {:error, "couldn't create #{dir}: #{format(reason)}"}

  # Each missing directory is created alone and made 0700; existing ones are
  # left as the operator set them.
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_private(dir) do
    case File.lstat(dir) do
      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        with :ok <- mkdir_private(Path.dirname(dir)),
             :ok <- mkdir_new(dir),
             do: File.chmod(dir, 0o700)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only the verified destination directory and its `db`/`media`/`.kiln-test`
  # subdirectories reach here (`ensure_dir/2`).
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_new(dir) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  # Copy, verify, then rename into place: `target` exists only once whole.
  # A step that lost its lease gets `{:error, :superseded}` from the rename.
  # The partial keeps a fresh mtime until then (touched again after the
  # hash, which on a large file takes a while), so another put's sweep never
  # takes it for one a stopped node left; the source's mtime goes on the
  # target once it is in place.
  # sobelow_skip ["Traversal.FileModule"]
  defp place(source, {partial, target, rename}, file) do
    with :ok <- copy_verified(source, partial, file),
         :ok <- File.touch(partial) do
      before_rename(partial)

      case rename.(partial, target) do
        :ok -> keep_mtime(source, target)
        {:error, :superseded} = superseded -> superseded
        {:error, reason} -> {:error, "couldn't move #{file.name} into place: #{format(reason)}"}
      end
    end
  end

  # Copy into a new 0600 `partial` (made 0600 before a byte is written), then
  # hash what landed: the bytes and the sha256 the file verified with locally,
  # or the copy is refused.
  # `partial` is `put/3`'s verified target plus its temporary suffix.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_verified(source, partial, file) do
    File.rm(partial)

    with :ok <- copy_private(source, partial),
         {:ok, digest, bytes} <- Checksum.file(partial) do
      if digest == String.downcase(to_string(file[:sha256])) and bytes == file[:bytes] do
        :ok
      else
        {:error,
         "the copy of #{file.name} did not match its checksum (#{bytes} of #{file[:bytes]} " <>
           "bytes); nothing was kept"}
      end
    else
      {:error, reason} -> {:error, "couldn't copy #{file.name}: #{format(reason)}"}
    end
  end

  # As `copy_verified/3`: paths `put/3` built and verified.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_private(source, partial) do
    with {:ok, device} <- File.open(partial, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(partial, 0o600),
             {:ok, _bytes} <- File.copy(source, device),
             do: :ok
      after
        File.close(device)
      end
    end
  end

  # Only `test/1`'s random probe name under the verified directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_private(file, body) do
    with {:ok, device} <- File.open(file, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(file, 0o600), do: IO.binwrite(device, body)
      after
        File.close(device)
      end
    end
  end

  # `config :kiln_cms, KilnCMS.Backups.Destination.Local, before_rename:`, a
  # function of the temporary file's path, run between the verified copy and
  # its rename: tests only, to hold a step there.
  defp before_rename(partial) do
    case Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), :before_rename) do
      nil -> :ok
      fun -> fun.(partial)
    end
  end

  # Best-effort: the file is already in place and verified.
  # sobelow_skip ["Traversal.FileModule"]
  defp keep_mtime(source, target) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(source, time: :posix),
         do: File.touch(target, mtime)

    :ok
  end

  defp entries(dir, subdir) do
    path = Path.join(dir, subdir)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, names} <- File.ls(path) do
      for name <- Enum.sort(names),
          Destination.backup_file?(name),
          {:ok, %File.Stat{type: :regular} = stat} <-
            [File.lstat(Path.join(path, name), time: :posix)] do
        %{subdir: subdir, name: name, bytes: stat.size, mtime: DateTime.from_unix!(stat.mtime)}
      end
    else
      _missing_or_not_a_directory -> []
    end
  end

  # Only `delete/2`'s `safe_ref/2` basename under `checked/1`'s directory,
  # lstat'ed as a regular file first.
  # sobelow_skip ["Traversal.FileModule"]
  defp rm(target) do
    case File.rm(target) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "couldn't delete #{target}: #{format(reason)}"}
    end
  end

  defp safe_ref(subdir, name) do
    if subdir in @subdirs and is_binary(name) and name == Path.basename(name) and
         name not in ["", ".", ".."],
       do: :ok,
       else: {:error, "#{inspect(subdir)}/#{inspect(name)} is not a backup file"}
  end

  ## Paths

  # `path` is `dir` or inside it, compared by whole segments.
  defp within?(path, dir), do: List.starts_with?(segments(path), segments(dir))

  defp segments(path), do: path |> Path.split() |> Enum.reject(&(&1 in ["/", "."]))

  # "/", "/a", "/a/b", … down to `path`.
  defp prefixes(path) do
    path
    |> segments()
    |> Enum.scan("/", &Path.join(&2, &1))
    |> then(&["/" | &1])
  end

  # `dir` with every symbolic link in it resolved, so an excluded directory
  # reached through a link is still recognized. A part that doesn't exist is
  # kept as written.
  defp real(dir), do: dir |> Path.expand() |> segments() |> resolve("/", 0)

  defp resolve(_rest, acc, depth) when depth > @max_links, do: acc
  defp resolve([], acc, _depth), do: acc

  defp resolve([segment | rest], acc, depth) do
    candidate = Path.join(acc, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        target |> Path.expand(acc) |> segments() |> Kernel.++(rest) |> resolve("/", depth + 1)

      {:error, _not_a_link} ->
        resolve(rest, candidate, depth)
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason) when is_atom(reason), do: reason |> :file.format_error() |> to_string()
  defp format(reason), do: inspect(reason)
end
