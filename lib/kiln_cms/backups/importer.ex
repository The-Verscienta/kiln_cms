defmodule KilnCMS.Backups.Importer do
  @moduledoc """
  Turns backups this application did not record into `KilnCMS.Backups.Run` rows
  (#2217), so the history shows cron-made backups next to app-made ones.

  ## The files are the truth; the manifest only enriches

  `scripts/backup.sh` writes `kiln-db-<stamp>.dump` / `kiln-media-<stamp>.tar.gz`
  under `db/` and `media/`, and a `manifest.json` that describes only the LAST
  run (and only for `all`). So the importer scans the two directories, groups
  files by the stamp in their names, and creates one run per stamp. The manifest
  is consulted for a stamp only when its artifact paths carry that stamp: then
  its trigger, outcome, error, times, `verified` flags and off-site remote are
  used. A failed manifest with no stamped files at all becomes a `failed` run
  keyed by the stamp of its `started_at`.

  ## What an imported run is

  `origin: :imported`, trigger `"cron"` unless a manifest says otherwise,
  `verified: false` and `sha256: nil` (nothing is hashed or verified on import),
  `succeeded` unless a file is zero bytes (`failed`, "empty artifact").
  `started_at` is the stamp read as UTC; `finished_at` is the newest file's
  mtime. Components are inferred from the files.

  ## Safe to run at any time

    * **Idempotent.** Existing stamps come from one `select stamp` query and a
      set difference; only new stamps are stat'ed. The write is an upsert that
      does nothing on a conflicting stamp, so a run the application owns (still
      `running`, or finished) or a previous import is never modified, and two
      concurrent calls cannot double-insert.
    * **Settled.** A stamp with no covering manifest is left for a later call
      until its newest file is at least #{10} minutes old and no matching
      `.partial` exists, so a cron run still writing is not recorded half-done.
    * **Bounded.** It lists two directories and stats files of new stamps only;
      it never walks the tree or reads a file's contents. A directory with
      thousands of backups costs one listing plus one insert per new stamp.
    * **Total.** A missing directory is "nothing to import"; an unreadable one
      is `{:error, _}`. Nothing raises, so it is safe inside `start_async` and
      at the tail of the worker. A file named like an artifact that is a
      directory or symlink, or a stamp that is not a real instant, is skipped.
    * **Independent** of `BACKUP_ENABLED` and of `pg_dump` being installed.

  Runs as `KilnCMS.Backups.system/0` and fails closed: with the grant revoked it
  reports `{:error, _}` and writes nothing.

  Separate cron entries (`backup.sh db`, then `backup.sh media`) have different
  stamps, so they become two runs.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Manifest}

  require Logger

  @settle_ms :timer.minutes(10)
  @max_trigger 64

  @type summary :: %{
          imported: non_neg_integer(),
          pending: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Import every backup found on disk that has no run yet.

  Returns `{:ok, summary}` — `imported` rows written (a concurrent call may
  have written the same stamp, in which case the write was a no-op but is still
  counted), `pending` stamps waiting out the settle window, `skipped` stamps
  that cannot be represented (impossible date), `failed` rows whose write
  errored — or `{:error, reason}` when the directory cannot be listed or the
  runs cannot be read.
  """
  @spec run() :: {:ok, summary()} | {:error, term()}
  def run, do: run(Backups.dir())

  @doc false
  @spec run(Path.t()) :: {:ok, summary()} | {:error, term()}
  def run(dir) do
    reconcile_stale_runs()

    with {:ok, names} <- list(dir),
         {:ok, existing} <- existing_stamps() do
      import_new(dir, names, existing)
    end
  rescue
    error ->
      Logger.warning("Backup import crashed: #{Exception.message(error)}")
      {:error, {:crashed, error.__struct__}}
  end

  # Fail stale `running` runs first, so a killed worker's stamp reads as failed
  # rather than running. The sweep raises on a revoked grant; this boundary
  # downgrades that to a warning, and the read below then fails closed.
  defp reconcile_stale_runs do
    Backups.reconcile_stale_runs()
  rescue
    error -> Logger.warning("Couldn't sweep stale backup runs: #{Exception.message(error)}")
  end

  defp existing_stamps do
    case Backups.list_runs(
           query: [select: [:stamp]],
           actor: Backups.system(),
           authorize_with: :error
         ) do
      {:ok, runs} -> {:ok, MapSet.new(runs, & &1.stamp)}
      {:error, error} -> {:error, {:read_runs, error.__struct__}}
    end
  end

  # `%{stamp => [%{kind, name, partial?}]}` from names alone — no stat yet. A
  # missing subdirectory is an empty one (S3 deployments have no `media/`); any
  # other failure aborts, since a half-seen stamp would be recorded wrong forever.
  defp list(dir) do
    Enum.reduce_while(["db", "media"], {:ok, []}, fn sub, {:ok, acc} ->
      case File.ls(Path.join(dir, sub)) do
        {:ok, names} ->
          {:cont, {:ok, acc ++ Enum.map(names, &{sub, &1})}}

        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          Logger.warning("Couldn't list #{sub}/ in the backup directory: #{inspect(reason)}")
          {:halt, {:error, {:ls, sub, reason}}}
      end
    end)
  end

  defp import_new(dir, listed, existing) do
    manifest = Manifest.read(dir)

    {files, partials} = classify(listed)

    {valid, invalid} =
      files
      |> Map.keys()
      |> Enum.split_with(&match?({:ok, _}, Artifact.parse_stamp(&1)))

    for stamp <- invalid,
        do: Logger.warning("Skipping a backup with an impossible stamp: #{stamp}")

    covered = covered_stamps(manifest)

    new = valid |> Enum.reject(&MapSet.member?(existing, &1)) |> Enum.sort()

    {ready, pending} =
      new
      |> Enum.map(&entry(dir, &1, files[&1]))
      |> Enum.reject(&(&1.files == []))
      |> Enum.split_with(&settled?(&1, partials, covered))

    attrs = Enum.map(ready, &run_attrs(&1, manifest, covered))
    manifest_only = failed_manifest_attrs(manifest, existing, files)

    results = Enum.map(attrs ++ manifest_only, &import_one/1)

    {:ok,
     %{
       imported: Enum.count(results, &(&1 == :ok)),
       pending: length(pending),
       skipped: length(invalid),
       failed: Enum.count(results, &(&1 == :error))
     }}
  end

  # `{files, partials}`: artifact names grouped by stamp, and the set of stamps
  # that still have a `.partial` (of either kind) beside them.
  defp classify(listed) do
    Enum.reduce(listed, {%{}, MapSet.new()}, fn {sub, name}, {files, partials} ->
      case Artifact.parse_name(name) do
        {:ok, kind, stamp, false} -> {add_file(files, sub, kind, stamp, name), partials}
        {:ok, _kind, stamp, true} -> {files, MapSet.put(partials, stamp)}
        :error -> {files, partials}
      end
    end)
  end

  # A file only counts in the directory its kind lives in.
  defp add_file(files, sub, kind, stamp, name) do
    if Artifact.subdir(kind) == sub,
      do: Map.update(files, stamp, [{kind, name}], &[{kind, name} | &1]),
      else: files
  end

  # Stat (lstat: a symlink or directory named like an artifact is not one) only
  # the files of a stamp we are about to create.
  defp entry(dir, stamp, names) do
    files =
      for {kind, name} <- names,
          path = Path.join([dir, Artifact.subdir(kind), name]),
          {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
            [File.lstat(path, time: :posix)] do
        %{kind: kind, name: name, bytes: size, mtime: mtime}
      end

    %{stamp: stamp, files: Enum.sort_by(files, & &1.kind)}
  end

  defp settled?(%{stamp: stamp, files: files}, partials, covered) do
    MapSet.member?(covered, stamp) or
      (not MapSet.member?(partials, stamp) and old_enough?(files))
  end

  defp old_enough?(files) do
    newest = files |> Enum.map(& &1.mtime) |> Enum.max()
    System.os_time(:millisecond) - newest * 1000 >= @settle_ms
  end

  # The stamps the manifest speaks for: those its artifact paths carry.
  defp covered_stamps(nil), do: MapSet.new()

  defp covered_stamps(%Manifest{} = manifest) do
    manifest.artifacts
    |> Enum.flat_map(fn artifact ->
      case Artifact.parse_name(Path.basename(artifact.path)) do
        {:ok, _kind, stamp, false} -> [stamp]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp run_attrs(%{stamp: stamp, files: files}, manifest, covered) do
    {:ok, started_at} = Artifact.parse_stamp(stamp)
    finished_at = files |> Enum.map(& &1.mtime) |> Enum.max() |> DateTime.from_unix!()
    manifest = if MapSet.member?(covered, stamp), do: manifest

    empty? = Enum.any?(files, &(&1.bytes == 0))

    {status, error} =
      case {manifest, empty?} do
        {%Manifest{ok: false, error: error}, _} -> {:failed, error}
        {_, true} -> {:failed, "empty artifact"}
        _ -> {:succeeded, nil}
      end

    %{
      stamp: stamp,
      trigger: trigger(manifest),
      status: status,
      components: files |> Enum.map(& &1.kind) |> Enum.uniq(),
      started_at: (manifest && manifest.started_at) || started_at,
      finished_at: (manifest && manifest.finished_at) || finished_at,
      error: error,
      log: [
        %{
          level: :info,
          step: "import",
          message: "Found in the backup directory; this application did not record the run"
        }
      ],
      artifacts: Enum.map(files, &artifact_attrs(&1, manifest))
    }
  end

  defp trigger(%Manifest{trigger: trigger}) when is_binary(trigger),
    do: String.slice(trigger, 0, @max_trigger)

  defp trigger(_none), do: "cron"

  defp artifact_attrs(file, manifest) do
    base = %{
      kind: file.kind,
      name: file.name,
      bytes: file.bytes,
      verified: false,
      destinations: %{"local" => %{"status" => "ok"}}
    }

    with %Manifest{} <- manifest,
         %{} = listed <- Enum.find(manifest.artifacts, &(Path.basename(&1.path) == file.name)),
         {:ok, attrs} <- Artifact.from_manifest(listed, manifest.offsite) do
      %{attrs | bytes: file.bytes}
    else
      _ -> base
    end
  end

  # A failed manifest naming no stamped file: the run has nothing on disk to be
  # found by, so it is keyed by the stamp of its start.
  defp failed_manifest_attrs(
         %Manifest{ok: false, started_at: %DateTime{} = at} = m,
         existing,
         files
       ) do
    stamp = Artifact.stamp(at)

    if Enum.any?(m.artifacts, &stamped?/1) or MapSet.member?(existing, stamp) or
         Map.has_key?(files, stamp) do
      []
    else
      [
        %{
          stamp: stamp,
          trigger: trigger(m),
          status: :failed,
          components: [],
          started_at: at,
          finished_at: m.finished_at,
          error: m.error || "The backup failed",
          log: [],
          artifacts: []
        }
      ]
    end
  end

  defp failed_manifest_attrs(_manifest, _existing, _files), do: []

  defp stamped?(artifact),
    do: match?({:ok, _, _, false}, Artifact.parse_name(Path.basename(artifact.path)))

  defp import_one(attrs) do
    case Backups.import_run(attrs, actor: Backups.system()) do
      {:ok, _run} ->
        :ok

      {:error, error} ->
        Logger.warning("Couldn't import backup #{attrs.stamp}: #{error.__struct__}")
        :error
    end
  end
end
