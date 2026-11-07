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
  alias KilnCMS.Backups.{Artifact, Importer, Manifest, Recorder, Redact}

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
  def perform(%Oban.Job{id: id, args: args}) do
    run(Map.get(args, "trigger", "manual"), id)
  end

  @doc """
  Perform a backup synchronously. Public so a release console can take one
  (`KilnCMS.Backups.Worker.run("console")`) without going through Oban.
  """
  @spec run(String.t(), integer() | nil) :: :ok | {:error, term()}
  def run(trigger, job_id \\ nil) do
    started_at = DateTime.utc_now()
    dir = Backups.dir()

    case Backups.availability() do
      :ok ->
        execute(dir, trigger, started_at, job_id)

      {:error, reason} ->
        # NOT recorded as a failed backup. "This image has no pg_dump" is a
        # fact about the app, not about the backups — and cron may be backing
        # this deployment up perfectly from the host. Writing `ok: false` here
        # would overwrite cron's record of a SUCCESSFUL backup and turn the
        # overview red, destroying the very information the panel exists to
        # show. `availability/0` already tells the console why the button is
        # disabled.
        Logger.warning("Backup refused (#{reason}) — leaving the existing manifest untouched")

        # The ATTEMPT is history (a `skipped` run); the manifest still is not
        # touched.
        Recorder.skip(
          Artifact.stamp(started_at),
          trigger,
          started_at,
          planned_components(),
          "Refused: #{reason}"
        )

        {:error, reason}
    end
  end

  defp execute(dir, trigger, started_at, job_id) do
    stamp = Artifact.stamp(started_at)
    reconcile_stale_runs()

    rec =
      stamp
      |> Recorder.open(trigger, started_at, planned_components(), job_id)
      |> Recorder.log(:info, "start", "Backup started (#{trigger})")

    sweep_stale_partials(dir)

    result =
      case artifacts(dir, stamp, rec) do
        {:ok, artifacts, rec} ->
          rec = prune_step(dir, rec)
          {offsite, rec} = offsite_step(dir, artifacts, rec)

          # The manifest FIRST: it has no database dependency, and cron-era
          # consumers read it. The run is closed after.
          write_manifest(dir, %Manifest{
            started_at: started_at,
            finished_at: DateTime.utc_now(),
            trigger: trigger,
            ok: true,
            artifacts: artifacts,
            offsite: offsite && Redact.text(offsite),
            keep_days: Backups.keep_days()
          })

          rec
          |> Recorder.log(:info, "done", "Backup complete: #{length(artifacts)} artifact(s)")
          |> Recorder.finish()

          Logger.info("Backup complete (#{trigger}): #{length(artifacts)} artifact(s) in #{dir}")
          :ok

        {:error, reason, partial, rec} ->
          Logger.error("Backup FAILED (#{trigger}): #{inspect(reason)}")
          error = describe(reason)
          record_failure(dir, trigger, started_at, error, partial)
          Recorder.fail(rec, error)
          {:error, reason}
      end

    # Last, so a cron-made backup sitting next to this one is picked up too.
    # The importer is total; nothing it does changes the backup's outcome.
    _ = Importer.run()
    result
  end

  # Time-based, not Oban-state-based (`Worker.run/1` may come from a console).
  # A revoked grant raises there; this is a job tail, so it is a warning.
  defp reconcile_stale_runs do
    Backups.reconcile_stale_runs()
  rescue
    error ->
      Logger.warning("Couldn't sweep stale backup runs: #{Exception.message(error)}")
      0
  end

  defp planned_components do
    if Backups.media_dir(), do: [:db, :media], else: [:db]
  end

  defp prune_step(dir, rec) do
    deleted = prune(dir)
    Recorder.mark_pruned(deleted)

    rec =
      case deleted do
        [] -> rec
        names -> Recorder.log(rec, :info, "prune", "Removed #{length(names)} expired file(s)")
      end

    Recorder.progress(rec)
  end

  # Per-artifact outcomes land on the run; the manifest keeps its all-or-nothing
  # `offsite` (the remote, or nil), exactly as before.
  defp offsite_step(dir, artifacts, rec) do
    case offsite_results(dir, artifacts) do
      nil ->
        {nil, rec}

      {remote, results} ->
        key = "rclone:" <> Redact.text(remote)
        rec = Enum.reduce(results, rec, &record_offsite(&1, &2, key))
        {offsite_remote(remote, results), Recorder.progress(rec)}
    end
  end

  defp record_offsite({artifact, result}, rec, key) do
    result = with {:error, reason} <- result, do: {:error, describe(reason)}
    level = if result == :ok, do: :info, else: :warn

    rec
    |> Recorder.put_destination(Path.basename(artifact.path), key, result)
    |> Recorder.log(level, "offsite", offsite_message(artifact, result))
  end

  defp offsite_message(artifact, :ok), do: "Copied #{Path.basename(artifact.path)} off-site"

  defp offsite_message(artifact, {:error, error}),
    do: "Off-site copy of #{Path.basename(artifact.path)} failed: #{error}"

  # The database always; the media archive only on a Local-adapter deployment.
  # On S3 the bucket is backed up provider-side, and tarring an empty or
  # unrelated directory would produce something that looks like a media backup
  # and restores nothing — the failure mode this whole module exists to avoid.
  # Returns the artifacts that DID land alongside any error, because the
  # database dump is renamed into place before the media archive is attempted.
  # Reporting `artifacts: []` on a media failure left a verified `.dump` on
  # disk that the panel never mentioned — a real backup, invisible.
  defp artifacts(dir, stamp, rec) do
    case dump_database(dir, stamp) do
      {:ok, db} ->
        rec =
          rec
          |> Recorder.add_artifact(db)
          |> Recorder.log(:info, "dump", "Database dump verified (#{db.bytes} bytes)")
          |> Recorder.progress()

        media_artifacts(dir, stamp, db, rec)

      {:error, reason} ->
        {:error, reason, [], Recorder.log(rec, :error, "dump", describe(reason))}
    end
  end

  defp media_artifacts(dir, stamp, db, rec) do
    case maybe_archive_media(dir, stamp) do
      {:ok, media} ->
        rec = media |> Enum.reduce(rec, &record_media/2) |> Recorder.progress()
        {:ok, [db | media], rec}

      {:error, reason} ->
        {:error, reason, [db], Recorder.log(rec, :error, "media", describe(reason))}
    end
  end

  defp record_media(media, rec) do
    rec
    |> Recorder.add_artifact(media)
    |> Recorder.log(:info, "media", "Media archive verified (#{media.bytes} bytes)")
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
         {url, env} = split_credentials(Backups.database_url()),
         :ok <-
           cmd(
             "pg_dump",
             [
               "--format=custom",
               "--no-owner",
               "--no-privileges",
               "--file=#{target}.partial",
               url
             ],
             env
           ),
         :ok <- cmd("pg_restore", ["--list", "#{target}.partial"]),
         :ok <- File.rename("#{target}.partial", target),
         :ok <- File.chmod(target, 0o600) do
      {:ok, artifact("db", dir, target)}
    else
      error ->
        File.rm("#{target}.partial")
        fail(error)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp archive_media(dir, media_dir, stamp) do
    target = Path.join([dir, "media", "kiln-media-#{stamp}.tar.gz"])

    with :ok <- media_dir_exists(media_dir),
         :ok <- mkdir_private(Path.dirname(target)),
         # `-C` so the archive holds relative paths and restores anywhere —
         # same as the script.
         :ok <- cmd("tar", ["-czf", "#{target}.partial", "-C", media_dir, "."]),
         :ok <- cmd("tar", ["-tzf", "#{target}.partial"]),
         :ok <- File.rename("#{target}.partial", target),
         :ok <- File.chmod(target, 0o600) do
      {:ok, artifact("media", dir, target)}
    else
      error ->
        File.rm("#{target}.partial")
        fail(error)
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

  @doc """
  Copies fresh artifacts to the configured rclone remote, returning the remote
  it used or `nil`.

  Without this the app path silently produced a **local-only** backup on a
  deployment whose cron path copies off-site — and, because the manifest's
  `offsite` field then defaulted to `nil`, the panel stopped mentioning the
  remote at all. An admin would have seen a green "backed up" for the one
  backup that wasn't safe from losing the machine.

  Best-effort and never fatal: an off-site copy that failed is worth knowing
  about, and is not a reason to throw away a verified local backup. A failure
  logs and reports `nil`, which reads on the panel as "no off-site copy" —
  the truthful answer.
  """
  @spec copy_offsite(Path.t(), [map()]) :: String.t() | nil
  def copy_offsite(dir, artifacts) do
    case offsite_results(dir, artifacts) do
      nil -> nil
      {remote, results} -> offsite_remote(remote, results)
    end
  end

  # All-or-nothing, as `copy_offsite/2` has always answered.
  defp offsite_remote(remote, results) do
    if Enum.all?(results, fn {_artifact, result} -> result == :ok end) do
      remote
    else
      Logger.error("Off-site copy to #{Redact.text(remote)} FAILED — the local backup is fine")
      nil
    end
  end

  # The per-artifact truth behind `copy_offsite/2`: `nil` when no remote or no
  # `rclone` is configured, else the remote and one `:ok | {:error, reason}`
  # per artifact. An error's rclone output has been through `Redact` (see
  # `cmd/3`), so it is safe to store and show.
  defp offsite_results(dir, artifacts) do
    with remote when is_binary(remote) <- Backups.rclone_remote(),
         exe when is_binary(exe) <- System.find_executable("rclone") do
      results =
        for artifact <- artifacts do
          # Mirrors the script's `rclone copy <file> <remote>/<subdir>`.
          subdir = artifact.path |> Path.dirname() |> Path.basename()
          {artifact, cmd(exe, ["copy", Path.join(dir, artifact.path), "#{remote}/#{subdir}"])}
        end

      {remote, results}
    else
      _ -> nil
    end
  end

  # Partials left behind by a job Oban's timeout killed, or a node that
  # restarted mid-dump. Nothing else reclaims them: the `else` cleanup in
  # `dump_database`/`archive_media` doesn't run when the process is killed,
  # and `prune/1` deliberately skips `.partial` so it can't delete a
  # CONCURRENT run's work. An hour's grace makes that distinction — anything
  # older than that has no live writer, because `timeout/1` caps a job well
  # inside it and this queue runs one job at a time.
  #
  # Each of these is potentially a full-database-sized file, so leaving them
  # is how a backup directory fills a disk.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_stale_partials(dir) do
    cutoff = System.os_time(:second) - 3600

    for sub <- ["db", "media"],
        path <- Path.wildcard(Path.join([dir, sub, "*.partial"])),
        match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix)) do
      Logger.warning("Removing an abandoned backup partial: #{Path.basename(path)}")
      File.rm(path)
    end

    :ok
  end

  # Deletes artifacts older than `keep_days`, matching the script's `prune`,
  # and returns the file names it removed (so their runs can say `pruned`).
  # Best-effort and never fatal: failing a backup that succeeded because its
  # housekeeping didn't would be exactly backwards.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune(dir) do
    # `(keep_days + 1) * 86400`, not `keep_days * 86400`, to match the shell's
    # `find -mtime +N`: that deletes only files whose age in WHOLE days is
    # strictly greater than N, i.e. age >= (N+1) days. Off by one here meant a
    # 14-day-6-hour dump was kept by cron and deleted by the app.
    cutoff =
      DateTime.add(DateTime.utc_now(), -(Backups.keep_days() + 1) * 24 * 60 * 60, :second)

    for sub <- ["db", "media"],
        path <- Path.wildcard(Path.join([dir, sub, "kiln-*"])),
        not String.ends_with?(path, ".partial"),
        older_than?(path, cutoff),
        File.rm(path) == :ok do
      Path.basename(path)
    end
  rescue
    error ->
      Logger.warning("Backup prune failed (backup itself succeeded): #{inspect(error)}")
      []
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp older_than?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime < DateTime.to_unix(cutoff)
      _ -> false
    end
  end

  # A run that STARTED and failed writes a manifest. Leaving the previous,
  # successful one in place would tell an admin the last backup was fine —
  # true, and not the question they are asking.
  #
  # `partial` carries whatever genuinely landed and verified before the
  # failure, so a media error doesn't hide a perfectly good database dump.
  defp record_failure(dir, trigger, started_at, error, partial) do
    write_manifest(dir, %Manifest{
      started_at: started_at,
      finished_at: DateTime.utc_now(),
      trigger: trigger,
      ok: false,
      artifacts: partial,
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
  defp cmd(executable, args, env \\ []) do
    case System.cmd(executable, args, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:exit_status, executable, status, redact(output, env)}}
    end
  rescue
    error -> {:error, {executable, error}}
  end

  @doc """
  Splits a connection URL into a password-free URL plus a `PGPASSWORD`
  environment entry.

  The password must not be an **argv** element. `System.cmd/3` uses no shell,
  so there is no injection risk — but argv is not private: `/proc/<pid>/cmdline`
  is world-readable (0444, unlike `environ`'s 0400), the host's `ps` shows a
  container's argv, and process-monitoring agents scrape it by default. A dump
  runs for minutes, so `postgres://user:secret@host/db` would sit there in
  plain sight for the duration, inside the long-lived application container.

  Returns the URL unchanged with an empty env when there is no password to
  move — `pg_dump` then falls back to `PGPASSFILE`/peer auth as it always did.
  """
  @spec split_credentials(String.t() | nil) :: {String.t() | nil, [{String.t(), String.t()}]}
  def split_credentials(nil), do: {nil, []}

  def split_credentials(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} = uri when is_binary(userinfo) ->
        case String.split(userinfo, ":", parts: 2) do
          [user, password] when password != "" ->
            {URI.to_string(%{uri | userinfo: user}), [{"PGPASSWORD", URI.decode(password)}]}

          _ ->
            {url, []}
        end

      _ ->
        {url, []}
    end
  end

  # This string reaches the manifest, which the console renders.
  #
  # The scrubbing itself (known secrets, URL userinfo, `key=value`) lives in
  # `KilnCMS.Backups.Redact`, the single path every backup text goes through
  # (#2217); this just bounds the diagnostic to 500 characters.
  defp redact(output, env), do: Redact.text(output, env, 500)

  # 0700/0600 throughout. A `.dump` is a complete logical copy of the database
  # — password hashes, session and API tokens, every row of PII — and the
  # default umask would leave it 0644 in a 0755 directory. On any deployment
  # where BACKUP_DIR is a bind mount or a shared volume, that is readable by
  # every uid on the box.
  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir_private(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp media_dir_exists(media_dir) do
    if File.dir?(media_dir), do: :ok, else: {:error, {:missing_media_dir, media_dir}}
  end

  # Every step in both `with`s returns `:ok`/`{:ok, _}` or `{:error, _}`, so
  # this is the only shape the `else` can see.
  defp fail({:error, reason}), do: {:error, reason}

  defp describe({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{output}"

  defp describe(reason), do: inspect(reason)
end
