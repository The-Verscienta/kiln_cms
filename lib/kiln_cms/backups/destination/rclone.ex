defmodule KilnCMS.Backups.Destination.Rclone do
  @moduledoc """
  A backup destination reached through `rclone` (#2220): the env destination
  `BACKUP_RCLONE_REMOTE`, and stored destinations on a remote already named
  in rclone's own configuration.

  Two shapes of `Kiln.BackupDestination.Config`, one adapter:

    * **The env destination** (built by `KilnCMS.Backups.Destination`):
      settings `"remote"`, the remote as `KilnCMS.Backups.RcloneRemote`
      leaves it, and `"display"`, its redacted form; the connection string's
      parameters arrive as secrets, the `RCLONE_CONFIG_*` environment `rclone`
      runs with. `put/3` therefore runs exactly the command the off-site step
      always ran: `rclone copy <path> <remote>/<subdir>`, with that
      environment, through `KilnCMS.Backups.Command`.
    * **A stored destination** (decision E7): settings `"remote_name"`, a
      remote `rclone listremotes` knows, and `"path"` under it. No inline
      connection string and no local path, so the database holds no rclone
      secret and a form can't make the app write files on its own host.
      Credentials stay in rclone.conf or the `RCLONE_CONFIG_*` environment.

  A missing `rclone` is `{:error, :missing_rclone}` from every call that
  needs it, before anything is touched.

  `location/1` normalizes where a destination writes, so two destinations
  that are the same place, or one inside the other, can be told apart from
  two that are not (`KilnCMS.Backups.Destination.overlap?/2`). It compares
  names, not what they point at: an rclone `alias` remote, or two names for
  one bucket, can't be detected.
  """

  use Kiln.BackupDestination

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.{Command, Destination, RcloneRemote}

  # Subdirectories a backup's files live in, as `scripts/backup.sh` lays
  # them out.
  @subdirs ["db", "media"]

  # Where `test/1` writes its probe: never under `db/` or `media/`, and its
  # name never parses as a backup's.
  @test_dir ".kiln-test"

  # Appended to every command whose output is data (`cat`, `lsjson`,
  # `listremotes`) or that has no output worth keeping (`copyto`,
  # `deletefile`): `Command` merges stderr into the output, so a NOTICE from
  # rclone's config loading would otherwise end up in what is compared or
  # parsed. Errors still print at this level. Not on the env destination's
  # `copy`, whose argv stays exactly what the off-site step always ran.
  @quiet ["-q"]

  # rclone's exit codes for "directory not found" and "file not found".
  @not_found [3, 4]

  # A remote name as rclone allows it, minus anything that would make the
  # setting more than a name: `:` (a path or an inline backend), `,` (inline
  # parameters), `/` and `\` (a local path). A leading `-` would read as a flag.
  @remote_name ~r/\A[A-Za-z0-9_][A-Za-z0-9_.+@ -]{0,63}\z/

  @impl Kiln.BackupDestination
  def kind, do: "rclone"

  @impl Kiln.BackupDestination
  def label, do: "Rclone remote"

  @impl Kiln.BackupDestination
  def fields do
    [
      %{
        name: "remote_name",
        type: :string,
        required?: true,
        help: "A remote already defined in the server's rclone configuration, without the colon."
      },
      %{
        name: "path",
        type: :string,
        required?: false,
        help: "The directory on that remote, e.g. a bucket and prefix: kiln-backups/site."
      }
    ]
  end

  @impl Kiln.BackupDestination
  def supports, do: [:list, :delete]

  @impl Kiln.BackupDestination
  def validate(%Config{settings: %{"remote" => _remote}}),
    do: {:error, "the remote is set by BACKUP_RCLONE_REMOTE in the server's environment"}

  def validate(%Config{settings: settings}) do
    with {:ok, name} <- remote_name(settings),
         {:ok, _path} <- remote_path(settings) do
      listed(name)
    end
  end

  @impl Kiln.BackupDestination
  def test(config) do
    with {:ok, exe} <- executable(),
         {:ok, {remote, env}} <- target(config) do
      probe(exe, remote, env)
    end
  end

  @impl Kiln.BackupDestination
  def put(config, %{path: path, subdir: subdir}, _opts) do
    with {:ok, exe} <- executable(),
         {:ok, {remote, env}} <- target(config) do
      # Mirrors the script's `rclone copy <file> <remote>/<subdir>`.
      Command.cmd(exe, ["copy", path, "#{remote}/#{subdir}"], env)
    end
  end

  @impl Kiln.BackupDestination
  def list(config) do
    with {:ok, exe} <- executable(),
         {:ok, {remote, env}} <- target(config) do
      Enum.reduce_while(@subdirs, {:ok, []}, &list_into(exe, remote, env, &1, &2))
    end
  end

  defp list_into(exe, remote, env, subdir, {:ok, acc}) do
    case list_subdir(exe, remote, env, subdir) do
      {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp list_subdir(exe, remote, env, subdir) do
    case Command.output(exe, ["lsjson", "--files-only", "#{remote}/#{subdir}" | @quiet], env) do
      {:ok, json} -> parse_listing(subdir, json)
      # A destination nothing was sent to yet has no `db/` or `media/`.
      {:error, {:exit_status, _exe, status, _output}} when status in @not_found -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @impl Kiln.BackupDestination
  def get(config, %{subdir: subdir, name: name}, to) do
    with {:ok, exe} <- executable(),
         {:ok, {remote, env}} <- target(config),
         :ok <- safe_ref(subdir, name) do
      Command.cmd(exe, ["copyto", "#{remote}/#{subdir}/#{name}", to | @quiet], env)
    end
  end

  @impl Kiln.BackupDestination
  def delete(config, %{subdir: subdir, name: name}) do
    with {:ok, exe} <- executable(),
         {:ok, {remote, env}} <- target(config),
         :ok <- safe_ref(subdir, name) do
      case Command.cmd(exe, ["deletefile", "#{remote}/#{subdir}/#{name}" | @quiet], env) do
        {:error, {:exit_status, _exe, status, _output}} when status in @not_found -> :ok
        result -> result
      end
    end
  end

  @impl Kiln.BackupDestination
  def describe(%Config{settings: %{"display" => display}}) when is_binary(display), do: display

  def describe(%Config{settings: settings}) do
    "#{Map.get(settings, "remote_name", "")}:#{Map.get(settings, "path") || ""}"
  end

  ## Location

  @typedoc """
  Where a destination writes, normalized: an rclone remote's name and the
  path segments under it, or a local directory's segments.
  """
  @type location :: {:rclone, String.t(), [String.t()]} | {:local, [String.t()]}

  @doc """
  `config`'s location, or a remote string's (`BACKUP_RCLONE_REMOTE`).
  `foo:bar`, `foo:bar/` and `foo:/bar` are one location; a remote with no
  `name:` (rclone's local path) is `{:local, segments}`, expanded, so it can
  be compared with a Local destination. A connection string is compared by
  the name rclone gets for it (`kiln_offsite`), so it overlaps nothing stored.
  """
  @spec location(Config.t() | String.t()) :: location()
  def location(%Config{settings: %{"remote" => remote}}) when is_binary(remote),
    do: location(remote)

  def location(%Config{settings: settings}) do
    location("#{Map.get(settings, "remote_name", "")}:#{Map.get(settings, "path") || ""}")
  end

  def location(remote) when is_binary(remote) do
    {bare, _env} = RcloneRemote.split_credentials(remote)

    case split_remote(bare) do
      {:ok, name, path} -> {:rclone, name, segments(path)}
      :local -> {:local, bare |> Path.expand() |> segments()}
    end
  end

  # `name:path`. A leading `:` is an inline backend (`:s3:bucket`), whose name
  # runs to the next `:`. No `:` at all, or a `/` before it, is a local path.
  defp split_remote(":" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [backend, path] -> {:ok, ":" <> backend, path}
      [_only] -> :local
    end
  end

  defp split_remote(remote) do
    case String.split(remote, ":", parts: 2) do
      [name, path] when name != "" ->
        if String.contains?(name, "/"), do: :local, else: {:ok, name, path}

      _ ->
        :local
    end
  end

  @doc false
  @spec segments(String.t()) :: [String.t()]
  def segments(path) do
    path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))
  end

  ## Internals

  defp executable do
    case System.find_executable("rclone") do
      nil -> {:error, :missing_rclone}
      exe -> {:ok, exe}
    end
  end

  # `{remote, env}` for rclone: the env destination's split remote and its
  # `RCLONE_CONFIG_*` secrets, or a stored one's `name:path` with no
  # environment of its own. A stored one is re-checked on every call, not
  # only when it was saved.
  defp target(%Config{settings: %{"remote" => remote}, secrets: secrets})
       when is_binary(remote) do
    # The order of environment entries means nothing to rclone.
    {:ok, {remote, Enum.to_list(secrets)}}
  end

  defp target(%Config{settings: settings}) do
    with {:ok, name} <- remote_name(settings),
         {:ok, path} <- remote_path(settings) do
      {:ok, {name <> ":" <> path, []}}
    end
  end

  defp remote_name(%{"remote_name" => name}) when is_binary(name) do
    if name =~ @remote_name,
      do: {:ok, name},
      else:
        {:error, "the remote name must be the name of a remote in rclone.conf, without a colon"}
  end

  defp remote_name(_settings), do: {:error, "the remote name is missing"}

  defp remote_path(settings) do
    case Map.get(settings, "path") do
      nil ->
        {:ok, ""}

      path when is_binary(path) ->
        cond do
          path =~ ~r/[\x00-\x1f\x7f]/ -> {:error, "the path must not contain control characters"}
          ".." in String.split(path, "/") -> {:error, "the path must not contain .."}
          true -> {:ok, path |> segments() |> Enum.join("/")}
        end

      _other ->
        {:error, "the path must be text"}
    end
  end

  defp listed(name) do
    with {:ok, exe} <- executable(),
         {:ok, output} <- Command.output(exe, ["listremotes" | @quiet], []) do
      remotes =
        output |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, ":"))

      if name in remotes,
        do: :ok,
        else: {:error, "rclone has no remote named #{name}; define it in rclone.conf first"}
    end
  end

  defp safe_ref(subdir, name) do
    if subdir in @subdirs and is_binary(name) and name == Path.basename(name) and
         name not in ["", ".", ".."],
       do: :ok,
       else: {:error, "#{inspect(subdir)}/#{inspect(name)} is not a backup file"}
  end

  # Write a probe under `.kiln-test/`, read it back, remove it. Removed also
  # when a step fails: a Test must leave nothing behind.
  # `local` is a fresh random name in the system temp directory, removed in
  # the `after`; nothing of it comes from the destination's settings.
  # sobelow_skip ["Traversal.FileModule"]
  defp probe(exe, remote, env) do
    hex = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    name = "kiln-test-#{hex}.txt"
    body = "Kiln backup destination test #{hex}\n"
    local = Path.join(System.tmp_dir!(), name)
    target = "#{remote}/#{@test_dir}/#{name}"

    try do
      with :ok <- File.write(local, body),
           :ok <- File.chmod(local, 0o600),
           :ok <- Command.cmd(exe, ["copyto", local, target | @quiet], env),
           {:ok, read} <- Command.output(exe, ["cat", target | @quiet], env) do
        if read == body,
          do: :ok,
          else: {:error, "the test file read back from the remote differs from what was written"}
      end
    after
      File.rm(local)
      Command.cmd(exe, ["deletefile", target | @quiet], env)
    end
  end

  # One subdirectory's `rclone lsjson --files-only` output. Names that are
  # not a backup's (another tool's files, a `.partial` upload) are left out.
  @doc false
  @spec parse_listing(String.t(), binary()) ::
          {:ok, [Kiln.BackupDestination.entry()]} | {:error, String.t()}
  def parse_listing(subdir, output) do
    with {:ok, json} <- json_array(output),
         {:ok, items} when is_list(items) <- Jason.decode(json) do
      {:ok,
       for %{"Name" => name} = item <- items,
           is_binary(name),
           item["IsDir"] != true,
           Destination.backup_file?(name) do
         %{subdir: subdir, name: name, bytes: bytes(item["Size"]), mtime: mtime(item["ModTime"])}
       end}
    else
      _ -> {:error, "rclone lsjson returned a listing that could not be read"}
    end
  end

  # rclone writes notices to stderr, which `Command` merges into the output:
  # the listing starts at the first line that opens the JSON array.
  defp json_array(output) do
    case Regex.run(~r/^\[.*/ms, output) do
      [json] -> {:ok, json}
      nil -> :error
    end
  end

  defp bytes(size) when is_integer(size) and size >= 0, do: size
  defp bytes(_other), do: 0

  defp mtime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _reason} -> nil
    end
  end

  defp mtime(_other), do: nil
end
