defmodule KilnCMS.Backups.Worker do
  @moduledoc """
  Runs one backup (#484) — the "Backup now" button, and anything else that
  wants a backup taken from inside the application.

  Produces exactly what `scripts/backup.sh` produces: same directory layout,
  same filenames, same `pg_dump` flags, same verification, same manifest. See
  `KilnCMS.Backups` for why that identity is a requirement rather than a
  nicety.

  ## Its own queue, deliberately

  `:backups` rather than `:default`. A dump of a large database holds its
  worker for minutes, and the alternative is a publish or a password-reset
  email queued behind it. One concurrent worker, because two simultaneous
  `pg_dump`s of the same database is never what anyone wanted — and because
  the whole point of a manifest is that there is a most-recent backup.

  ## Nothing is a backup until it verifies

  Every artifact is written to `<name>.partial` and renamed only after it
  passes (`pg_restore --list` for a dump, `tar -tzf` for an archive). An
  aborted or corrupt run leaves a `.partial` that nothing will ever mistake
  for a backup — which is the discipline the shell script has always had, and
  the reason a failed backup here is loud rather than a truncated file with a
  plausible name.

  ## Uniqueness

  Oban `unique` over a short window stops the obvious double-click from
  starting a second `pg_dump`, and `:backups` having a concurrency of one
  means even a race that slipped past it queues rather than overlaps.
  """
  use Oban.Worker,
    queue: :backups,
    max_attempts: 1,
    # `:incomplete` rather than an explicit state list: naming states by hand
    # omits `:retryable` and `:suspended`, and a "unique" job that a suspended
    # twin doesn't block is not unique.
    unique: [period: 300, states: Oban.Job.states() -- [:completed, :discarded, :cancelled]]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Manifest

  require Logger

  @doc """
  Ceiling on one backup, enforced by Oban.

  `pg_dump` is an external process this worker cannot signal (closing an
  Erlang port shuts the pipes but sends no signal — the same constraint
  `KilnCMS.Media.AVWorker` documents), so this bounds the *job*, not the
  child. It exists so a hung dump surfaces as a failed backup instead of a
  queue slot that never returns.
  """
  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(2)

  # `max_attempts: 1` on purpose: a backup that failed should be visible and
  # re-run deliberately, not retried into a pile of half-finished dumps whose
  # only trace is three identical error lines.
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    run(Map.get(args, "trigger", "manual"))
  end

  @doc """
  Perform a backup synchronously. Public so a release console can take one
  (`KilnCMS.Backups.Worker.run("console")`) without going through Oban.
  """
  @spec run(String.t()) :: :ok | {:error, term()}
  def run(trigger) do
    started_at = DateTime.utc_now()
    dir = Backups.dir()

    case Backups.availability() do
      :ok ->
        execute(dir, trigger, started_at)

      {:error, reason} ->
        Logger.warning("Backup refused: #{reason}")
        record_failure(dir, trigger, started_at, to_string(reason))
        {:error, reason}
    end
  end

  defp execute(dir, trigger, started_at) do
    stamp = stamp(started_at)

    case artifacts(dir, stamp) do
      {:ok, artifacts} ->
        prune(dir)

        write_manifest(dir, %Manifest{
          started_at: started_at,
          finished_at: DateTime.utc_now(),
          trigger: trigger,
          ok: true,
          artifacts: artifacts,
          keep_days: Backups.keep_days()
        })

        Logger.info("Backup complete (#{trigger}): #{length(artifacts)} artifact(s) in #{dir}")
        :ok

      {:error, reason} ->
        Logger.error("Backup FAILED (#{trigger}): #{inspect(reason)}")
        record_failure(dir, trigger, started_at, describe(reason))
        {:error, reason}
    end
  end

  # The database always; the media archive only on a Local-adapter deployment.
  # On S3 the bucket is backed up provider-side, and tarring an empty or
  # unrelated directory would produce something that looks like a media backup
  # and restores nothing — the failure mode this whole module exists to avoid.
  defp artifacts(dir, stamp) do
    with {:ok, db} <- dump_database(dir, stamp),
         {:ok, media} <- maybe_archive_media(dir, stamp) do
      {:ok, [db | media]}
    end
  end

  # A list rather than a nullable artifact, so the caller concatenates instead
  # of branching — the S3 case (no media archive) and the Local case differ
  # only in how many artifacts came back.
  defp maybe_archive_media(dir, stamp) do
    case Backups.media_dir() do
      nil -> {:ok, []}
      media_dir -> with {:ok, media} <- archive_media(dir, media_dir, stamp), do: {:ok, [media]}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp dump_database(dir, stamp) do
    target = Path.join([dir, "db", "kiln-db-#{stamp}.dump"])

    with :ok <- File.mkdir_p(Path.dirname(target)),
         # Identical flags to scripts/backup.sh: custom format so `pg_restore`
         # can go table-by-table, and no-owner/no-privileges so a restore
         # doesn't depend on the production role existing on the target.
         :ok <-
           cmd("pg_dump", [
             "--format=custom",
             "--no-owner",
             "--no-privileges",
             "--file=#{target}.partial",
             Backups.database_url()
           ]),
         :ok <- cmd("pg_restore", ["--list", "#{target}.partial"]),
         :ok <- File.rename("#{target}.partial", target) do
      {:ok, artifact("db", dir, target)}
    else
      error ->
        File.rm("#{target}.partial")
        fail(:database, error)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp archive_media(dir, media_dir, stamp) do
    target = Path.join([dir, "media", "kiln-media-#{stamp}.tar.gz"])

    with true <- File.dir?(media_dir) || {:error, {:missing_media_dir, media_dir}},
         :ok <- File.mkdir_p(Path.dirname(target)),
         # `-C` so the archive holds relative paths and restores anywhere —
         # same as the script.
         :ok <- cmd("tar", ["-czf", "#{target}.partial", "-C", media_dir, "."]),
         :ok <- cmd("tar", ["-tzf", "#{target}.partial"]),
         :ok <- File.rename("#{target}.partial", target) do
      {:ok, artifact("media", dir, target)}
    else
      error ->
        File.rm("#{target}.partial")
        fail(:media, error)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp artifact(kind, dir, target) do
    bytes =
      case File.stat(target) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    # Relative to the backup directory, so the manifest survives the directory
    # being moved or read from another mount.
    %{kind: kind, path: Path.relative_to(target, dir), bytes: bytes, verified: true}
  end

  # Deletes artifacts older than `keep_days`, matching the script's `prune`.
  # Best-effort and never fatal: failing a backup that succeeded because its
  # housekeeping didn't would be exactly backwards.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune(dir) do
    cutoff = DateTime.add(DateTime.utc_now(), -Backups.keep_days() * 24 * 60 * 60, :second)

    for sub <- ["db", "media"],
        path <- Path.wildcard(Path.join([dir, sub, "kiln-*"])),
        not String.ends_with?(path, ".partial"),
        older_than?(path, cutoff) do
      File.rm(path)
    end

    :ok
  rescue
    error ->
      Logger.warning("Backup prune failed (backup itself succeeded): #{inspect(error)}")
      :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp older_than?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < DateTime.to_unix(cutoff)
      _ -> false
    end
  end

  defp record_failure(dir, trigger, started_at, error) do
    # A failed run still writes a manifest. Leaving the previous, successful
    # one in place would tell an admin the last backup was fine — which is
    # true, and is not the question they are asking.
    write_manifest(dir, %Manifest{
      started_at: started_at,
      finished_at: DateTime.utc_now(),
      trigger: trigger,
      ok: false,
      artifacts: [],
      keep_days: Backups.keep_days(),
      error: error
    })
  end

  defp write_manifest(dir, manifest) do
    case Manifest.write(dir, manifest) do
      :ok ->
        :ok

      {:error, reason} ->
        # Never fatal — see `Manifest.write/2`.
        Logger.warning("Couldn't write the backup manifest to #{dir}: #{inspect(reason)}")
        :ok
    end
  end

  # `System.cmd/3` with an argv list — no shell, so nothing here can be
  # injected into even though the database URL carries a password.
  #
  # stderr is captured rather than inherited so a failure can be reported with
  # its actual reason. It is NOT logged verbatim: `pg_dump`'s error output can
  # echo the connection string, and a backup failure should not put the
  # database password in the log.
  # sobelow_skip ["CI.System"]
  defp cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:exit_status, executable, status, redact(output)}}
    end
  rescue
    error -> {:error, {executable, error}}
  end

  # Anything that looks like a connection string loses its userinfo. Belt and
  # braces on top of not logging raw output: this string reaches the manifest,
  # which the console renders.
  defp redact(output) do
    output
    |> String.replace(~r{(?<scheme>[a-z][a-z0-9+.-]*://)[^@\s/]+@}i, "\\g{scheme}***@")
    |> String.slice(0, 500)
  end

  # Two shapes only: a step that returned `{:error, _}`, or the `File.dir?/1`
  # guard returning plain `false`. Nothing else can reach the `else`.
  defp fail(_stage, {:error, reason}), do: {:error, reason}
  defp fail(stage, false), do: {:error, stage}

  defp describe({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{output}"

  defp describe(reason), do: inspect(reason)

  # Byte-identical to `scripts/backup.sh`'s `date -u +%Y%m%d-%H%M%S`, so both
  # paths sort together in a directory listing and `restore.sh`'s "newest
  # matching glob" picks up whichever ran last regardless of which wrote it.
  defp stamp(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
