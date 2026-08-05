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
        # NOT recorded as a failed backup. "This image has no pg_dump" is a
        # fact about the app, not about the backups — and cron may be backing
        # this deployment up perfectly from the host. Writing `ok: false` here
        # would overwrite cron's record of a SUCCESSFUL backup and turn the
        # overview red, destroying the very information the panel exists to
        # show. `availability/0` already tells the console why the button is
        # disabled.
        Logger.warning("Backup refused (#{reason}) — leaving the existing manifest untouched")
        {:error, reason}
    end
  end

  defp execute(dir, trigger, started_at) do
    stamp = stamp(started_at)
    sweep_stale_partials(dir)

    case artifacts(dir, stamp) do
      {:ok, artifacts} ->
        prune(dir)

        offsite = copy_offsite(dir, artifacts)

        write_manifest(dir, %Manifest{
          started_at: started_at,
          finished_at: DateTime.utc_now(),
          trigger: trigger,
          ok: true,
          artifacts: artifacts,
          offsite: offsite,
          keep_days: Backups.keep_days()
        })

        Logger.info("Backup complete (#{trigger}): #{length(artifacts)} artifact(s) in #{dir}")
        :ok

      {:error, reason, partial} ->
        Logger.error("Backup FAILED (#{trigger}): #{inspect(reason)}")
        record_failure(dir, trigger, started_at, describe(reason), partial)
        {:error, reason}
    end
  end

  # The database always; the media archive only on a Local-adapter deployment.
  # On S3 the bucket is backed up provider-side, and tarring an empty or
  # unrelated directory would produce something that looks like a media backup
  # and restores nothing — the failure mode this whole module exists to avoid.
  # Returns the artifacts that DID land alongside any error, because the
  # database dump is renamed into place before the media archive is attempted.
  # Reporting `artifacts: []` on a media failure left a verified `.dump` on
  # disk that the panel never mentioned — a real backup, invisible.
  defp artifacts(dir, stamp) do
    case dump_database(dir, stamp) do
      {:ok, db} ->
        case maybe_archive_media(dir, stamp) do
          {:ok, media} -> {:ok, [db | media]}
          {:error, reason} -> {:error, reason, [db]}
        end

      {:error, reason} ->
        {:error, reason, []}
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
    with remote when is_binary(remote) <- Backups.rclone_remote(),
         exe when is_binary(exe) <- System.find_executable("rclone") do
      results =
        for artifact <- artifacts do
          # Mirrors the script's `rclone copy <file> <remote>/<subdir>`.
          subdir = artifact.path |> Path.dirname() |> Path.basename()
          cmd(exe, ["copy", Path.join(dir, artifact.path), "#{remote}/#{subdir}"])
        end

      if Enum.all?(results, &(&1 == :ok)) do
        remote
      else
        Logger.error("Off-site copy to #{remote} FAILED — the local backup is fine")
        nil
      end
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

  # Deletes artifacts older than `keep_days`, matching the script's `prune`.
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
  # Two passes, in order of reliability. First the KNOWN secret is removed
  # literally — that catches `password=…` keyword conninfo, a `PGPASSWORD`
  # echo, and a password containing characters the pattern below can't match.
  # Then the generic userinfo pattern as a backstop.
  #
  # `\\1`, NOT `\\g{name}`: `Regex.replace/4` supports numbered groups only,
  # and a named reference makes it RAISE — on exactly the input this exists to
  # sanitize, which is how the previous version managed to be simultaneously
  # dead code and the reason every failure recorded a `MatchError` instead of
  # pg_dump's actual message.
  # `@min_literal_secret`: a very short password appears as a substring of
  # ordinary words, and blanking every occurrence turned "pg_dump: error…"
  # into "***g_dum***: error…" — a redaction that destroys the diagnostic
  # while protecting a secret the userinfo pattern below already covers in the
  # only place it can plausibly appear. Long enough to be a real password,
  # short enough that anything meaningful is still caught literally.
  @min_literal_secret 6

  defp redact(output, env) do
    env
    |> Enum.reduce(output, fn {_var, secret}, acc ->
      if String.length(secret) >= @min_literal_secret,
        do: String.replace(acc, secret, "***"),
        else: acc
    end)
    |> String.replace(~r{([a-z][a-z0-9+.-]*://)[^@\s/]+@}i, "\\1***@")
    |> String.slice(0, 500)
  end

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

  # Byte-identical to `scripts/backup.sh`'s `date -u +%Y%m%d-%H%M%S`, so both
  # paths sort together in a directory listing and `restore.sh`'s "newest
  # matching glob" picks up whichever ran last regardless of which wrote it.
  defp stamp(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
