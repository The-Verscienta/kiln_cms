defmodule KilnCMS.Backups.Run.Actions.Download do
  @moduledoc """
  `KilnCMS.Backups.Run`'s `:check_download` and `:download` actions (part of
  #2225): may this platform admin have the local file `file` of the run
  `run_id`, and where is it.

  The policy has decided who may ask by the time this runs (a platform admin,
  and nobody else: no system actor). The run is read as that admin. With
  `audit: true` (`:download`) the `backup_downloaded` instance event is
  recorded **last**, after every check passed and the file was opened for
  reading, and nothing is returned unless it was written: the caller
  (`KilnCMSWeb.BackupDownloadController`) only ever gets a path once the event
  exists. `:check_download` runs the same checks and writes nothing.

  ## The checks, in order

    1. `origin_refusal/0`: never while the console shares an origin with
       several organizations' sites (threat model, residual 16), and never
       while that can't be told (an org count that can't be read, a node
       that hasn't counted yet).
    2. The requested name's shape: a binary of at most 255 bytes with no
       `/`, `\\` or NUL.
    3. The run, read as the admin.
    4. Its origin: `:app` and `:imported` only. A rescanned (`:found`) or
       foreign origin a later release adds is refused until it has a
       decision of its own (#2225 rescan, ADR 0064).
    5. Not in progress: not `:running`, and not the stamp the backup lock
       holds (a resume or re-send of it). A lock that can't be read refuses.
    6. The name, byte for byte, against the names derived from the row: a
       file of an artifact whose names `KilnCMS.Backups.Artifact.checked_files/2`
       accepts, or the `.sha256` sidecar of such an artifact. The client's
       string is compared, never parsed into a path.
    7. Not pruned here: a file whose `"local"` marker is `"pruned"` (its own,
       else the artifact's) is refused even if a file of that name is still on
       disk, and a sidecar when every file of its artifact is.
    8. The directory pin: a run that records a `dir_id` (#2539) is served only
       from that backup directory; an id that can't be read refuses.
    9. The path, built from `KilnCMS.Backups.dir/0`, the kind's subdirectory
       and the matched name, must stay under that subdirectory.
   10. `File.lstat/1`: a regular file (a symlink or anything else is
       `:not_regular`), whose size is the download's.
   11. It opens for reading, so a file the server can't read is refused
       before the event says it was downloaded.
   12. With `audit: true`, the event.

  A refusal is a `KilnCMS.Backups.Refused` carrying the reason, which
  `KilnCMS.Backups.check_download/3` and `download/4` unwrap: `:console_shares_origin`,
  `:not_found`, `:forbidden`, `:in_progress`, `{:lock_unreadable, reason}`,
  `:pruned`, `{:other_directory, dir_id}`, `{:dir_id_unreadable, reason}`,
  `:missing`, `:not_regular`, `:unreadable` or `:audit_failed`.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, DirId, Refused, Run}
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.Plugs.ConsoleHost
  alias KilnCMSWeb.Tenant
  alias KilnCMSWeb.Tenant.OrgCount

  # The origins whose files are served. `:app` is the worker's, `:imported`
  # cron's as the importer found them. Anything else is refused until it has
  # its own decision.
  @served_origins [:app, :imported]

  @max_name_bytes 255

  @impl true
  def run(input, opts, context) do
    actor = context.actor
    file = Ash.ActionInput.get_argument(input, :file)

    with :ok <- origin_ok(),
         :ok <- name_shape(file),
         {:ok, run} <- fetch_run(Ash.ActionInput.get_argument(input, :run_id), actor),
         :ok <- served(run),
         :ok <- not_in_progress(run),
         {:ok, match} <- resolve(run, file),
         :ok <- not_pruned(match),
         {:ok, dir, dir_id} <- dir_pin(run),
         {:ok, path} <- path(dir, match),
         {:ok, bytes} <- regular(path),
         :ok <- readable(path),
         download = %{
           path: path,
           name: match.name,
           kind: match.kind,
           bytes: bytes,
           stamp: run.stamp,
           dir_id: dir_id
         },
         :ok <- audit(Keyword.get(opts, :audit, false), download, run, actor, input) do
      {:ok, download}
    else
      {:error, reason} -> {:error, Refused.exception(reason: reason)}
    end
  end

  @doc """
  Why downloads are refused on this node right now, or `nil` when they are
  not: `:console_shares_origin` while `KILN_CONSOLE_HOST` is unset and there
  is more than one organization, or that can't be told.
  """
  @spec origin_refusal() :: :console_shares_origin | nil
  def origin_refusal do
    origin_refusal(ConsoleHost.console_host(), Tenant.org_count(), org_verdict())
  end

  @doc """
  The pure half of `origin_refusal/0`: from the console host (nil when
  unset), the organization count (`KilnCMSWeb.Tenant.org_count/0`) and this
  node's `KilnCMSWeb.Tenant.OrgCount` verdict.

  Fails closed, unlike the boot warning `Tenant.console_shares_origin?/1`: a
  count that can't be read (`:unknown`) refuses, and so does a verdict that
  isn't `:single` (a node that hasn't managed to count yet, or that heard of a
  second organization).
  """
  @spec origin_refusal(String.t() | nil, non_neg_integer() | :unknown, OrgCount.verdict()) ::
          :console_shares_origin | nil
  def origin_refusal(console_host, _count, _verdict) when is_binary(console_host), do: nil
  def origin_refusal(nil, count, :single) when is_integer(count) and count <= 1, do: nil
  def origin_refusal(nil, _count, _verdict), do: :console_shares_origin

  # The verdict is only evidence where this node keeps it. `config/test.exs`
  # switches the tracking off, so nothing ever counts and it stays `:unknown`
  # (`OrgCount`'s "Tests"); the count read just now decides alone there.
  defp org_verdict, do: if(OrgCount.tracking?(), do: OrgCount.verdict(), else: :single)

  @doc """
  This node's backup-directory id (`KilnCMS.Backups.DirId.current/1`), or
  nil when it has none or it can't be read: what a download link carries from
  the click to the request, so a request that reached another server is told
  so (part of #2225).
  """
  @spec current_dir_id() :: String.t() | nil
  def current_dir_id do
    case DirId.current(Backups.dir()) do
      {:ok, id} -> id
      {:error, _reason} -> nil
    end
  end

  @doc """
  Whether a run of `origin` is one whose files are served: `:app` and
  `:imported`. Anything a later release adds is refused until it has its own
  decision.
  """
  @spec served_origin?(term()) :: boolean()
  def served_origin?(origin), do: origin in @served_origins

  defp origin_ok do
    case origin_refusal() do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp name_shape(file)
       when is_binary(file) and byte_size(file) > 0 and byte_size(file) <= @max_name_bytes do
    if String.contains?(file, ["/", "\\", <<0>>]), do: {:error, :not_found}, else: :ok
  end

  defp name_shape(_file), do: {:error, :not_found}

  defp fetch_run(run_id, actor) do
    case Backups.get_run(run_id, actor: actor) do
      {:ok, %Run{} = run} -> {:ok, run}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, _not_found} -> {:error, :not_found}
    end
  end

  defp served(%Run{origin: origin}),
    do: if(served_origin?(origin), do: :ok, else: {:error, :not_found})

  defp not_in_progress(%Run{status: :running}), do: {:error, :in_progress}

  # Fails closed, as `KilnCMS.Backups.Verify` does: a lock that can't be read
  # may hold this stamp.
  defp not_in_progress(%Run{stamp: stamp}) do
    case held_stamp().() do
      {:ok, ^stamp} -> {:error, :in_progress}
      {:ok, _other_or_none} -> :ok
      {:error, reason} -> {:error, {:lock_unreadable, reason}}
    end
  end

  # `%{name, kind, files, file, artifact}`: `file` is the matched file of the
  # artifact (nil for its sidecar), `files` all of that artifact's.
  defp resolve(%Run{artifacts: artifacts, stamp: stamp}, file) do
    Enum.find_value(artifacts, {:error, :not_found}, fn artifact ->
      case Artifact.checked_files(artifact, stamp) do
        {:ok, files} -> match(artifact, files, stamp, file)
        {:error, _detail} -> nil
      end
    end)
  end

  defp match(artifact, files, stamp, file) do
    base = %{kind: artifact.kind, files: files, artifact: artifact}

    cond do
      found = Enum.find(files, &(&1.name == file)) ->
        {:ok, Map.merge(base, %{name: found.name, file: found})}

      file == Artifact.sidecar_name(artifact.kind, stamp) and sidecar?(file, artifact.kind, stamp) ->
        {:ok, Map.merge(base, %{name: file, file: nil})}

      true ->
        nil
    end
  end

  defp sidecar?(name, kind, stamp),
    do:
      match?(
        {:ok, %{kind: ^kind, stamp: ^stamp, partial?: false}},
        Artifact.parse_sidecar_name(name)
      )

  # A file pruned here is refused whatever is on disk under its name; a
  # sidecar once every file of its artifact is.
  defp not_pruned(%{file: nil, files: files, artifact: artifact}) do
    if Enum.all?(files, &Artifact.pruned_here?(&1, artifact)),
      do: {:error, :pruned},
      else: :ok
  end

  defp not_pruned(%{file: file, artifact: artifact}),
    do: if(Artifact.pruned_here?(file, artifact), do: {:error, :pruned}, else: :ok)

  # `{:ok, dir, this node's dir id or nil}`. A run pinned to a directory is
  # only served from it; an unpinned one (imported, or from before #2539)
  # is whatever file of its name is here.
  defp dir_pin(%Run{dir_id: nil}) do
    dir = Backups.dir()

    case DirId.current(dir) do
      {:ok, id} -> {:ok, dir, id}
      {:error, _reason} -> {:ok, dir, nil}
    end
  end

  defp dir_pin(%Run{dir_id: pinned}) do
    dir = Backups.dir()

    case DirId.current(dir) do
      {:ok, ^pinned} -> {:ok, dir, pinned}
      {:ok, _other} -> {:error, {:other_directory, pinned}}
      {:error, reason} -> {:error, {:dir_id_unreadable, reason}}
    end
  end

  # The matched name is already one of the row's, which `checked_files/2`
  # held to a bare file name; the prefix check is belt and braces.
  defp path(dir, %{kind: kind, name: name}) do
    sub = Path.join(dir, Artifact.subdir(kind))
    path = Path.join(sub, name)

    if String.starts_with?(Path.expand(path), Path.expand(sub) <> "/"),
      do: {:ok, path},
      else: {:error, :not_found}
  end

  # `lstat`, never `stat`: a symlink named like the file is not it. The path
  # is `Backups.dir/0`, `Artifact.subdir/1` and a name matched against the
  # row, never the client's string.
  # sobelow_skip ["Traversal.FileModule"]
  defp regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      {:error, :enoent} -> {:error, :missing}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  # Opened and closed again before the event is written: a file the server
  # can't read (`:eacces`) is refused, rather than audited as downloaded and
  # then failing mid-send. The same path `regular/1` checked.
  # sobelow_skip ["Traversal.FileModule"]
  defp readable(path) do
    case File.open(path, [:read, :raw]) do
      {:ok, io} ->
        :ok = File.close(io)
        :ok

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp audit(false, _download, _run, _actor, _input), do: :ok

  defp audit(true, download, run, actor, input) do
    result =
      recorder().(:backup_downloaded,
        scope: :instance,
        user: actor,
        target_type: "backup_run",
        target_id: run.id,
        metadata: %{
          "stamp" => download.stamp,
          "file" => download.name,
          "kind" => Atom.to_string(download.kind),
          "bytes" => download.bytes,
          "node" => to_string(node())
        },
        request: input.context[Recorder.context_key()]
      )

    case result do
      {:ok, _event} ->
        :ok

      other ->
        Logger.error(
          "backup download refused: the backup_downloaded event wasn't recorded " <>
            "(#{inspect(other)}); stamp=#{download.stamp} file=#{download.name}"
        )

        {:error, :audit_failed}
    end
  end

  # `config :kiln_cms, KilnCMS.Backups.Run.Actions.Download, recorder: ...,
  # held_stamp: ...`: seams for the tests (a recorder that fails, a lock that
  # can't be read). Never set outside them.
  defp recorder, do: Keyword.get(config(), :recorder, &Recorder.record/2)
  defp held_stamp, do: Keyword.get(config(), :held_stamp, &Chain.fetch_held_stamp/0)
  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
