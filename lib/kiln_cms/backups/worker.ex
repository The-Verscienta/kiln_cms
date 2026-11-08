defmodule KilnCMS.Backups.Worker do
  @moduledoc """
  Runs one backup (#484) — the "Backup now" button, and anything else that
  wants a backup taken from inside the application.

  Produces what `scripts/backup.sh` produces: same directory layout, same
  database dump name, `pg_dump` flags and verification, same manifest, and the
  same media parts (#2218): a library larger than `Backups.media_part_bytes/0`
  becomes several independent `kiln-media-<stamp>.partNN.tar.gz` parts
  (`KilnCMS.Backups.MediaArchive`, which the script mirrors), with `sha256`
  sidecars. The difference is recovery: work in flight lives in
  `<BACKUP_DIR>/.work/<stamp>/` (`KilnCMS.Backups.WorkState`) so a failed run
  can be resumed (see `run/3`), where a failed cron run removes its unfinished
  set. See
  `KilnCMS.Backups` for why one shared format is a requirement rather than a
  nicety.

  ## Its own queue, deliberately

  `:backups` rather than `:default`. A dump of a large database holds its
  worker for minutes, and the alternative is a publish or a password-reset
  email queued behind it. One concurrent worker, because two simultaneous
  `pg_dump`s of the same database is never what anyone wanted — and because
  the whole point of a manifest is that there is a most-recent backup.

  ## Nothing is a backup until it verifies

  Every artifact is written to `<name>.partial` and renamed only after it
  passes (`pg_restore --list` for a dump, `tar -tzf` for an archive part). An
  aborted or corrupt run leaves a `.partial` that nothing will ever mistake
  for a backup — which is the discipline the shell script has always had, and
  the reason a failed backup here is loud rather than a truncated file with a
  plausible name.

  ## Nothing leaves the host unverified

  Each file's sha256 is recorded once, right after it verifies (or, on a
  resume, re-checked against `state.json`). Immediately before each off-site
  copy (the dump, every media part, every sidecar) the file is read again and
  compared with that record (`Checksum.recheck/3`, `Checksum.check_sidecar/2`).
  A file that changed in between is **refused**: not uploaded, never retried
  and never rebuilt in the same run, because something other than this backup
  wrote to the backup directory and that is the operator's to look at. The
  other files are still checked and copied one by one, and the run fails at
  the end naming every refused and every failed file. A failed `rclone copy`
  (after rclone's own retries) fails the run too. The work directory is kept
  until the off-site copy succeeds, so Resume retries it, rebuilding only a
  file that changed.

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

  alias KilnCMS.Backups.{
    Artifact,
    Checksum,
    Importer,
    Manifest,
    MediaArchive,
    Recorder,
    Redact,
    WorkState
  }

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
  # only trace is three identical error lines. The deliberate re-run is a
  # resume (#2218): args carrying `"resume"` continue that stamp's backup.
  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: args}) do
    # `Map.has_key?`, not a nil check: a job whose `resume` is present but
    # mangled must be refused, never quietly become a fresh backup.
    opts = if Map.has_key?(args, "resume"), do: [resume: args["resume"]], else: []
    run(Map.get(args, "trigger", "manual"), id, opts)
  end

  @doc """
  Perform a backup synchronously. Public so a release console can take one
  (`KilnCMS.Backups.Worker.run("console")`) without going through Oban.

  ## Resuming (#2218)

  `run(trigger, job_id, resume: stamp)` continues the failed or interrupted
  backup of `stamp` instead of starting one. The stamp is validated against
  `\\A\\d{8}-\\d{6}\\z` before any path is built, the stamp's Run must exist and
  be resumable (failed, or running and stale; see `KilnCMS.Backups.resumable_run/2`)
  and its `.work/<stamp>/state.json` must exist; anything else is
  `{:error, reason}` and never a fresh run. The resumed backup keeps the original
  stamp and `started_at` and re-opens the original Run (`:resume`).

  A database dump or media part is **reused** only when `state.json` recorded its
  sha256 and the file on disk still hashes to it; anything else is rebuilt (a
  rename over the old file). The media plan is the frozen one from the first
  attempt, so the parts are the same lists. Because finished parts are durable, a
  run too big for one attempt converges over repeated resumes.
  """
  @spec run(String.t(), integer() | nil, keyword()) :: :ok | {:error, term()}
  def run(trigger, job_id \\ nil, opts \\ []) do
    if Keyword.has_key?(opts, :resume),
      do: resume(Keyword.get(opts, :resume), job_id),
      else: fresh(trigger, job_id)
  end

  defp fresh(trigger, job_id) do
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

  # Nothing below `resumable_run/1` runs unless the stamp is well-formed, its
  # Run exists and may be resumed, and its state file is there. The stamp and
  # `started_at` are the ORIGINAL run's; the trigger too (the manifest says who
  # started the backup, not who resumed it).
  defp resume(stamp, _job_id) do
    dir = Backups.dir()

    with {:ok, run} <- Backups.resumable_run(stamp),
         :ok <- Backups.availability(),
         {:ok, rec} <- Recorder.reopen(run.stamp) do
      execute_resume(dir, run, rec)
    else
      {:error, reason} = error ->
        Logger.warning("Backup resume refused: #{inspect(reason)}")
        error
    end
  end

  defp execute(dir, trigger, started_at, job_id) do
    stamp = Artifact.stamp(started_at)
    reconcile_stale_runs()

    rec =
      stamp
      |> Recorder.open(trigger, started_at, planned_components(), job_id)
      |> Recorder.log(:info, "start", "Backup started (#{trigger})")

    pipeline(
      %{dir: dir, trigger: trigger, started_at: started_at, stamp: stamp, resume?: false},
      rec
    )
  end

  # Re-opened FIRST: the sweep below fails `running` runs that went quiet, and
  # this one was exactly that until `Recorder.reopen/1` flipped it back.
  defp execute_resume(dir, run, rec) do
    reconcile_stale_runs()
    rec = Recorder.log(rec, :info, "resume", "Backup resumed (#{run.trigger})")

    pipeline(
      %{
        dir: dir,
        trigger: run.trigger,
        started_at: run.started_at,
        stamp: run.stamp,
        resume?: true
      },
      rec
    )
  end

  defp pipeline(ctx, rec) do
    %{dir: dir, trigger: trigger, started_at: started_at} = ctx
    sweep_stale_partials(dir)
    sweep_work_dirs(dir)

    result =
      case artifacts(ctx, rec) do
        {:ok, artifacts, rec} ->
          rec = prune_step(dir, rec)

          case offsite_step(dir, artifacts, rec) do
            {:ok, offsite, rec} -> succeed(ctx, artifacts, offsite, rec)
            {:error, reason, rec} -> fail_offsite(ctx, artifacts, reason, rec)
          end

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

  defp succeed(ctx, artifacts, offsite, rec) do
    %{dir: dir, trigger: trigger} = ctx

    # The manifest FIRST: it has no database dependency, and cron-era
    # consumers read it. The run is closed after. On a resume this
    # overwrites the failed run's manifest with `ok: true` (atomic rename).
    write_manifest(dir, %Manifest{
      started_at: ctx.started_at,
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

    finish_work(ctx)
    Logger.info("Backup complete (#{trigger}): #{length(artifacts)} artifact(s) in #{dir}")
    :ok
  end

  # The local backup is whole and verified, but it did not all get off the
  # host (or a file changed before it could). The work directory stays, so
  # Resume retries the off-site copy; a refused file is no longer the file
  # `state.json` recorded, so the resume rebuilds exactly that one.
  defp fail_offsite(ctx, artifacts, reason, rec) do
    Logger.error("Backup FAILED (#{ctx.trigger}): #{inspect(reason)}")
    error = describe_offsite(reason, Backups.media_dir() != nil)
    record_failure(ctx.dir, ctx.trigger, ctx.started_at, error, unverify(artifacts, reason))
    Recorder.fail(rec, error)
    {:error, reason}
  end

  # Last, after the run is closed: a node that dies between the two leaves at
  # most a stale `.work/<stamp>`, which `sweep_work_dirs/2` removes in time.
  # sobelow_skip ["Traversal.FileModule"]
  defp finish_work(ctx) do
    File.rm_rf(WorkState.path(ctx.dir, ctx.stamp))
    :ok
  end

  # The manifest must not call a refused file verified.
  defp unverify(artifacts, {:offsite, %{refused: refused}}) do
    names = for {name, _reason} <- refused, do: name

    Enum.map(artifacts, fn artifact ->
      if Path.basename(artifact.path) in names,
        do: %{artifact | verified: false},
        else: artifact
    end)
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

  # Per-file outcomes land on the run (a part set's per-part results on its
  # parts, with the artifact-level aggregate worked out by the recorder); the
  # manifest keeps its all-or-nothing `offsite` (the remote, or nil). A sidecar
  # is copied with its artifact: its result is logged, not recorded as a
  # destination, because it is not an artifact — but a sidecar that was refused
  # or failed fails the step like any other file, since a part set without its
  # sidecar off-site cannot be restored from there (#2218).
  #
  # `{:ok, remote | nil, rec}` when every file arrived (or there is nothing to
  # do), else `{:error, {:offsite, %{refused: [...], failed: [...]}}, rec}`
  # listing `{file_name, reason}` for each file that did not.
  #
  # A remote set with no `rclone` in this image is NOT an error: the official
  # image ships without rclone, and a host's cron may be copying these files
  # off-site perfectly well. It is logged loudly instead, and the panel says so
  # (`Backups.status/0`).
  @doc false
  @spec offsite_step(Path.t(), [map()], Recorder.t()) ::
          {:ok, String.t() | nil, Recorder.t()} | {:error, term(), Recorder.t()}
  def offsite_step(dir, artifacts, rec) do
    case offsite_results(dir, artifacts) do
      nil ->
        {:ok, nil, rec}

      {:missing_rclone, remote} ->
        message =
          "BACKUP_RCLONE_REMOTE is set but rclone is not installed in this image; " <>
            "nothing was copied off-site"

        Logger.warning(message <> " (#{Redact.text(remote)})")
        {:ok, nil, rec |> Recorder.log(:warn, "offsite", message) |> Recorder.progress()}

      {remote, results} ->
        key = "rclone:" <> Redact.text(remote)
        rec = results |> Enum.reduce(rec, &record_offsite(&1, &2, key)) |> Recorder.progress()

        case offsite_problems(results) do
          %{refused: [], failed: []} -> {:ok, remote, rec}
          problems -> {:error, {:offsite, problems}, rec}
        end
    end
  end

  defp offsite_problems(results) do
    problems =
      Enum.reduce(results, %{refused: [], failed: []}, fn
        {_file, :ok}, acc ->
          acc

        {file, {:refused, reason}}, acc ->
          Map.update!(acc, :refused, &[{Path.basename(file.path), reason} | &1])

        {file, {:error, reason}}, acc ->
          Map.update!(acc, :failed, &[{Path.basename(file.path), reason} | &1])
      end)

    Map.new(problems, fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  defp record_offsite({file, :ok}, rec, key) do
    name = Path.basename(file.path)
    rec = if file[:sidecar?], do: rec, else: Recorder.put_destination(rec, name, key, :ok)
    Recorder.log(rec, :info, "offsite", "Copied #{name} off-site")
  end

  defp record_offsite({file, {:error, reason}}, rec, key) do
    name = Path.basename(file.path)
    error = describe(reason)

    rec =
      if file[:sidecar?],
        do: rec,
        else: Recorder.put_destination(rec, name, key, {:error, error})

    Recorder.log(rec, :error, "offsite", "Off-site copy of #{name} failed: #{error}")
  end

  # Loud on every surface: the log with both full digests, the Run log, the
  # destination ("Refused: …", never "ok"), and the artifact's `verified`.
  defp record_offsite({file, {:refused, reason}}, rec, key) do
    name = Path.basename(file.path)
    why = describe_refusal(reason)
    message = "Off-site copy of #{name} REFUSED: #{why}; it was not uploaded"
    Logger.error(message)

    rec =
      if file[:sidecar?],
        do: rec,
        else:
          rec
          |> Recorder.put_destination(name, key, {:error, "Refused: " <> why})
          |> Recorder.put_unverified(name)

    Recorder.log(rec, :error, "offsite", message)
  end

  # Full digests: this is what an operator compares against the file on disk.
  defp describe_refusal({:changed, %{expected: expected, actual: actual} = found}) do
    size =
      if found.expected_bytes != nil and found.expected_bytes != found.bytes,
        do: ", #{found.expected_bytes} bytes recorded, #{found.bytes} found",
        else: ""

    "changed on disk after this backup verified it (sha256 expected #{expected}, " <>
      "found #{actual}#{size})"
  end

  defp describe_refusal(reason), do: short_refusal(reason)

  defp short_refusal({:changed, %{expected: expected, actual: actual}}),
    do:
      "changed on disk after this backup verified it (sha256 expected " <>
        "#{String.slice(expected, 0, 12)}…, found #{String.slice(actual, 0, 12)}…)"

  defp short_refusal(:no_digest), do: "no sha256 was recorded for it, so it can't be vouched for"
  defp short_refusal(:not_regular), do: "it is no longer a regular file"
  defp short_refusal(:enoent), do: "it is missing"
  defp short_refusal(:sidecar_changed), do: "the checksum file changed after it was written"
  defp short_refusal(:malformed), do: "the checksum file is no longer well-formed"
  defp short_refusal(reason), do: "it could not be read (#{inspect(reason)})"

  defp short_failure({:exit_status, executable, status, _output}),
    do: "#{Path.basename(executable)} exited #{status}"

  defp short_failure({executable, _error}) when is_binary(executable),
    do: "#{Path.basename(executable)} could not be run"

  defp short_failure(_reason), do: "copy failed"

  @max_named 5

  # The run's (and the failure manifest's) error: names and a short reason per
  # file, at most five per section. rclone's own output is NOT here — it is in
  # the per-file Run log line and destination error, redacted and capped.
  @doc false
  @spec describe_offsite(term(), boolean()) :: String.t()
  def describe_offsite({:offsite, %{refused: refused, failed: failed}}, resumable?) do
    refused_text =
      if refused != [] do
        "Off-site copy REFUSED for #{count_files(refused)}: " <>
          named(refused, &short_refusal/1) <>
          ". Something other than this backup wrote to the backup directory: check the disk " <>
          "and anything with access to BACKUP_DIR before trusting this backup."
      end

    failed_text =
      if failed != [] do
        "Off-site copy FAILED for #{count_files(failed)}: " <>
          named(failed, &short_failure/1) <> "."
      end

    tail =
      if resumable?,
        do:
          "The local files are kept; Resume retries the off-site copy and rebuilds any file that changed.",
        else: "The local files are kept; run a new backup to try the off-site copy again."

    [refused_text, failed_text, tail] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp count_files([_]), do: "1 file"
  defp count_files(list), do: "#{length(list)} files"

  defp named(list, short) do
    shown =
      list |> Enum.take(@max_named) |> Enum.map_join(", ", fn {n, r} -> "#{n} (#{short.(r)})" end)

    case length(list) - @max_named do
      more when more > 0 -> "#{shown} and #{more} more"
      _ -> shown
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
  #
  # Four steps (#2218): dump, plan, archive (per part), checksum. Each is a
  # function of the directory, the stamp and what the earlier steps produced.
  # With a media directory configured, `.work/<stamp>/state.json` records each
  # step and each finished file's sha256 as it lands, which is what a resume
  # builds on; with none (S3) there is nothing durable to resume and no work
  # directory.
  defp artifacts(ctx, rec) do
    media_dir = Backups.media_dir()

    with {:ok, work_dir, rec} <- open_work(ctx, media_dir, rec) do
      case dump_step(ctx, work_dir, rec) do
        {:ok, db, rec} -> media_artifacts(ctx, media_dir, work_dir, db, rec)
        {:error, reason, rec} -> {:error, reason, [], rec}
      end
    end
  end

  defp open_work(_ctx, nil, rec), do: {:ok, nil, rec}

  # A resume uses the directory it found. A fresh run starts it clean: a
  # leftover directory under the same stamp (a stamp collision) must not lend
  # its frozen plan or its recorded hashes to a backup that has nothing to do
  # with them.
  defp open_work(%{resume?: true} = ctx, _media_dir, rec),
    do: {:ok, WorkState.path(ctx.dir, ctx.stamp), rec}

  # sobelow_skip ["Traversal.FileModule"]
  defp open_work(ctx, _media_dir, rec) do
    work_dir = WorkState.path(ctx.dir, ctx.stamp)
    File.rm_rf(work_dir)

    with :ok <- mkdir_private(Path.dirname(work_dir)),
         :ok <- mkdir_private(work_dir),
         :ok <- WorkState.write(work_dir, WorkState.new(ctx.stamp)) do
      {:ok, work_dir, rec}
    else
      {:error, reason} ->
        {:error, reason, [], Recorder.log(rec, :error, "media", describe(reason))}
    end
  end

  # Best-effort: a state that couldn't be written costs a rebuild on resume,
  # never the backup.
  defp record_state(nil, _stamp, _fun), do: :ok

  defp record_state(work_dir, stamp, fun) do
    case WorkState.update(work_dir, stamp, fun) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Couldn't record the backup's resume state: #{inspect(reason)}")
        :ok
    end
  end

  defp dump_step(ctx, work_dir, rec) do
    case reuse_dump(ctx, work_dir) do
      {:ok, db, at} ->
        rec =
          rec
          |> Recorder.add_artifact(db)
          |> Recorder.log(
            :info,
            "dump",
            "Database dump reused from the original attempt (written #{at}); sha256 re-verified (#{db.bytes} bytes)"
          )
          |> Recorder.progress()

        {:ok, db, rec}

      :build ->
        build_dump(ctx, work_dir, rec)
    end
  end

  defp build_dump(ctx, work_dir, rec) do
    case dump_database(ctx.dir, ctx.stamp) do
      {:ok, db} ->
        record_state(work_dir, ctx.stamp, fn state ->
          state
          |> WorkState.put_dump(%{
            name: Path.basename(db.path),
            bytes: db.bytes,
            sha256: db.sha256
          })
          |> WorkState.complete("dump")
        end)

        rec =
          rec
          |> Recorder.add_artifact(db)
          |> Recorder.log(:info, "dump", "Database dump verified (#{db.bytes} bytes)")
          |> Recorder.progress()

        {:ok, db, rec}

      {:error, reason} ->
        {:error, reason, Recorder.log(rec, :error, "dump", describe(reason))}
    end
  end

  # A dump is reused only if `state.json` recorded its digest AND the file on
  # disk still hashes to it (and has the recorded size). The name is rebuilt
  # from the stamp, never taken from the file.
  # sobelow_skip ["Traversal.FileModule"]
  defp reuse_dump(%{resume?: true} = ctx, work_dir) when is_binary(work_dir) do
    name = "kiln-db-#{ctx.stamp}.dump"
    target = Path.join([ctx.dir, "db", name])

    with {:ok, state} <- WorkState.read(work_dir),
         %{"name" => ^name, "bytes" => bytes, "sha256" => sha256} = entry <-
           WorkState.dump(state),
         # The off-site gate's own check, so a file reused here is one the
         # upload will accept (a symlink is rebuilt, never reused).
         :ok <- Checksum.recheck(target, sha256, bytes),
         :ok <-
           Checksum.write_sidecar(
             Path.join(Path.dirname(target), Artifact.sidecar_name(:db, ctx.stamp)),
             [{name, sha256}]
           ) do
      {:ok, artifact("db", ctx.dir, target, sha256, bytes), entry["at"]}
    else
      _ -> :build
    end
  end

  defp reuse_dump(_ctx, _work_dir), do: :build

  defp media_artifacts(ctx, media_dir, work_dir, db, rec) do
    case media_dir do
      # S3 or unconfigured: no media artifact, and that is not an error.
      nil ->
        {:ok, [db], rec}

      media_dir ->
        case media_steps(ctx, media_dir, work_dir, rec) do
          {:ok, entries, rec} ->
            {:ok, [db | entries], rec}

          {:error, reason, rec} ->
            {:error, reason, [db], Recorder.log(rec, :error, "media", describe(reason))}
        end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp media_steps(ctx, media_dir, work_dir, rec) do
    target_dir = Path.join(ctx.dir, "media")

    with {:ok, plan, rec} <- plan_step(ctx, media_dir, work_dir, target_dir, rec),
         {:ok, parts, rec} <- archive_step(ctx, plan, target_dir, work_dir, rec),
         {:ok, set, rec} <- checksum_step(ctx, plan, parts, target_dir, work_dir, rec) do
      # The work directory stays until the off-site copy succeeds (`pipeline/2`).
      {:ok, media_entries(parts), record_media(rec, parts, set)}
    else
      {:error, reason, rec} -> {:error, reason, rec}
      {:error, reason} -> {:error, reason, rec}
    end
  end

  # The plan is frozen at first creation. A resume loads it; only if it is gone
  # (planning never finished) is it made afresh, and then nothing recorded for
  # the old partition means anything: the recorded parts are forgotten and the
  # files of an earlier set under this stamp removed, so a leftover
  # `part04` cannot sit beside a new three-part set.
  defp plan_step(%{resume?: true} = ctx, media_dir, work_dir, target_dir, rec) do
    case MediaArchive.load_plan(media_dir, work_dir) do
      {:ok, plan} ->
        {:ok, plan,
         Recorder.log(
           rec,
           :info,
           "media",
           "Reusing the frozen plan: #{plan.files} file(s) in #{length(plan.parts)} part(s)"
         )}

      {:error, :no_plan} ->
        discard_media_files(target_dir, ctx.stamp)
        record_state(work_dir, ctx.stamp, &WorkState.clear_parts/1)
        plan_afresh(ctx, media_dir, work_dir, rec)
    end
  end

  defp plan_step(ctx, media_dir, work_dir, _target_dir, rec),
    do: plan_afresh(ctx, media_dir, work_dir, rec)

  defp plan_afresh(ctx, media_dir, work_dir, rec) do
    with {:ok, plan} <- MediaArchive.plan_or_load(media_dir, work_dir, stamp: ctx.stamp) do
      record_state(work_dir, ctx.stamp, &WorkState.complete(&1, "plan"))
      {:ok, plan, log_plan(rec, plan)}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp discard_media_files(target_dir, stamp) do
    for path <- Path.wildcard(Path.join(target_dir, "kiln-media-#{stamp}*")), do: File.rm(path)
    :ok
  end

  defp log_plan(rec, plan) do
    excluded =
      if plan.excluded > 0, do: ", #{plan.excluded} excluded by BACKUP_MEDIA_EXCLUDE", else: ""

    rec =
      Recorder.log(
        rec,
        :info,
        "media",
        "Planned #{plan.files} file(s) in #{length(plan.parts)} part(s)#{excluded}"
      )

    rec = log_unreadable(rec, plan)

    case Enum.count(plan.parts, & &1.oversize) do
      0 ->
        rec

      n ->
        Recorder.log(
          rec,
          :warn,
          "media",
          "#{n} file(s) larger than the part size were archived as parts of their own"
        )
    end
  end

  defp log_unreadable(rec, %{unreadable_names: 0}), do: rec

  defp log_unreadable(rec, plan) do
    Recorder.log(
      rec,
      :warn,
      "media",
      "#{plan.unreadable_names} file(s) NOT in this backup: their names cannot be represented " <>
        "in the server's file-name encoding (e.g. #{Enum.join(plan.unreadable_examples, ", ")})"
    )
  end

  # One part at a time (rather than `MediaArchive.archive/3`) so the state is
  # written and the Run touched after EACH part: that is what makes a resume
  # skip the finished ones, and what keeps a long archive from looking stale.
  defp archive_step(ctx, plan, target_dir, work_dir, rec) do
    case archive_parts(plan.parts, ctx, plan, target_dir, work_dir, rec, [], []) do
      {:ok, parts, reused, rec} ->
        record_state(work_dir, ctx.stamp, &WorkState.complete(&1, "archive"))
        {:ok, parts, log_reused(rec, reused, length(parts))}

      {:error, reason, done, reused, rec} ->
        {:error, reason, log_reused(log_dropped(rec, done), reused, length(plan.parts))}
    end
  end

  defp archive_parts([], _ctx, _plan, _target_dir, _work_dir, rec, done, reused),
    do: {:ok, Enum.reverse(done), Enum.reverse(reused), rec}

  defp archive_parts([part | rest], ctx, plan, target_dir, work_dir, rec, done, reused) do
    case reuse_part(ctx, plan, part, target_dir, work_dir) do
      {:ok, finished, at} ->
        rec = Recorder.progress(rec)

        archive_parts(rest, ctx, plan, target_dir, work_dir, rec, [finished | done], [
          {part.index, at} | reused
        ])

      :build ->
        case MediaArchive.archive_part(plan, part.index, target_dir) do
          {:ok, finished} ->
            record_state(work_dir, ctx.stamp, &WorkState.put_part(&1, finished))
            rec = rec |> log_dropped([finished]) |> Recorder.progress()

            archive_parts(rest, ctx, plan, target_dir, work_dir, rec, [finished | done], reused)

          {:error, reason} ->
            {:error, reason, Enum.reverse(done), Enum.reverse(reused), rec}
        end
    end
  end

  # A part is reused only if `state.json` recorded its digest AND the file in
  # the media directory still hashes to it with the recorded size. The name
  # comes from the frozen plan, not from the state file.
  # sobelow_skip ["Traversal.FileModule"]
  defp reuse_part(%{resume?: true}, plan, part, target_dir, work_dir) when is_binary(work_dir) do
    name = plan |> MediaArchive.names() |> Enum.at(part.index - 1)
    path = Path.join(target_dir, name)

    with {:ok, state} <- WorkState.read(work_dir),
         %{"name" => ^name, "bytes" => bytes, "sha256" => sha256} = entry <-
           WorkState.part(state, part.index),
         # The off-site gate's own check, so a file reused here is one the
         # upload will accept (a symlink is rebuilt, never reused).
         :ok <- Checksum.recheck(path, sha256, bytes) do
      {:ok,
       %{
         index: part.index,
         name: name,
         path: path,
         bytes: bytes,
         sha256: sha256,
         oversize: part.oversize,
         files: entry["files"] || part.files,
         dropped: 0,
         verified: true
       }, entry["at"]}
    else
      _ -> :build
    end
  end

  defp reuse_part(_ctx, _plan, _part, _target_dir, _work_dir), do: :build

  # The set now mixes times: say so on the Run.
  defp log_reused(rec, [], _total), do: rec

  defp log_reused(rec, reused, total) do
    indexes = Enum.map_join(reused, ", ", &elem(&1, 0))

    Recorder.log(
      rec,
      :info,
      "resume",
      "Reused #{length(reused)} of #{total} media part(s) from the original attempt " <>
        "(part #{indexes}), sha256 re-verified; the set mixes times"
    )
  end

  defp log_dropped(rec, parts) do
    Enum.reduce(parts, rec, fn
      %{dropped: dropped, name: name}, rec when dropped > 0 ->
        Recorder.log(
          rec,
          :warn,
          "media",
          "#{name}: #{dropped} file(s) vanished before they were archived"
        )

      _part, rec ->
        rec
    end)
  end

  defp checksum_step(ctx, plan, parts, target_dir, work_dir, rec) do
    case MediaArchive.checksum(plan, parts, target_dir) do
      {:ok, set} ->
        record_state(work_dir, ctx.stamp, &WorkState.complete(&1, "checksum"))
        {:ok, set, rec}

      {:error, reason} ->
        {:error, reason, rec}
    end
  end

  # One flat manifest entry per part, in part order.
  defp media_entries(parts) do
    total = length(parts)

    for part <- parts do
      %{
        kind: "media",
        path: Path.join("media", part.name),
        bytes: part.bytes,
        verified: part.verified and part.sha256 != nil,
        sha256: part.sha256,
        part: part.index,
        parts_total: total
      }
    end
  end

  # The run row holds ONE artifact per media set (`Artifact.group_files/1`);
  # `group_files` can't know the digest of the concatenation, so it is set here.
  defp record_media(rec, parts, set) do
    entries =
      for {part, entry} <- Enum.zip(parts, media_entries(parts)) do
        {:ok, attrs} = Artifact.from_manifest(entry)
        Map.put(attrs, :oversize, part.oversize)
      end

    attrs =
      entries
      |> Artifact.group_files()
      |> Enum.map(&Map.put(&1, :sha256, set.sha256))

    bytes = Enum.sum(Enum.map(parts, & &1.bytes))

    %{rec | artifacts: rec.artifacts ++ attrs}
    |> Recorder.log(
      :info,
      "media",
      "Media archive verified (#{length(parts)} part(s), #{bytes} bytes)"
    )
    |> Recorder.progress()
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp dump_database(dir, stamp) do
    name = "kiln-db-#{stamp}.dump"
    target = Path.join([dir, "db", name])

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
      checksummed(dir, stamp, name, target)
    else
      error ->
        File.rm("#{target}.partial")
        fail(error)
    end
  end

  # A dump with no checksum on record is not a backup the panel can vouch for;
  # don't leave one lying beside a failed run.
  # sobelow_skip ["Traversal.FileModule"]
  defp checksummed(dir, stamp, name, target) do
    with {:ok, sha256, hashed} <- Checksum.file(target),
         :ok <-
           Checksum.write_sidecar(
             Path.join(Path.dirname(target), Artifact.sidecar_name(:db, stamp)),
             [{name, sha256}]
           ) do
      {:ok, artifact("db", dir, target, sha256, hashed)}
    else
      error ->
        File.rm(target)
        fail(error)
    end
  end

  # `verified` is the conjunction the manifest promises: the listing passed
  # (the caller got here), the size on disk is the size hashed, and a digest is
  # on record.
  # sobelow_skip ["Traversal.FileModule"]
  defp artifact(kind, dir, target, sha256, hashed) do
    size =
      case File.stat(target) do
        {:ok, %{size: size}} -> size
        _ -> nil
      end

    # Relative to the backup directory, so the manifest survives the directory
    # being moved or read from another mount.
    %{
      kind: kind,
      path: Path.relative_to(target, dir),
      bytes: hashed,
      verified: size == hashed and is_binary(sha256),
      sha256: sha256
    }
  end

  @doc """
  Copies fresh artifacts to the configured rclone remote, returning the remote
  it used or `nil`.

  Without this the app path silently produced a **local-only** backup on a
  deployment whose cron path copies off-site — and, because the manifest's
  `offsite` field then defaulted to `nil`, the panel stopped mentioning the
  remote at all. An admin would have seen a green "backed up" for the one
  backup that wasn't safe from losing the machine.

  The remote only when every file, sidecars included, was re-verified and
  copied (#2218); `nil` when there is no remote, no `rclone`, or any file was
  refused or failed. `offsite_step/3` is what the worker runs: it records each
  file's outcome and fails the run on any of them.
  """
  @spec copy_offsite(Path.t(), [map()]) :: String.t() | nil
  def copy_offsite(dir, artifacts) do
    with {remote, results} when is_binary(remote) <- offsite_results(dir, artifacts),
         true <- Enum.all?(results, &match?({_file, :ok}, &1)) do
      remote
    else
      _ -> nil
    end
  end

  # The per-file truth behind `offsite_step/3`: `nil` when no remote is
  # configured, `{:missing_rclone, remote}` when one is but this image has no
  # `rclone`, else the remote and one `:ok | {:error, reason} | {:refused,
  # reason}` per file: one `rclone copy` for each part of a set (and each single
  # file), then one for each stamp's checksum sidecar, into the same `db/` or
  # `media/` subdirectory, in that order. Each file is re-checked immediately
  # before its own copy (not all up front, which would leave the whole upload
  # window open) and refused, without calling rclone, if it changed. An
  # error's rclone output has been through `Redact` (see `cmd/3`), so it is
  # safe to store and show.
  @doc false
  def offsite_results(dir, artifacts) do
    with remote when is_binary(remote) <- Backups.rclone_remote() do
      case System.find_executable("rclone") do
        nil ->
          {:missing_rclone, remote}

        exe ->
          files = artifacts ++ expected_sidecars(artifacts)
          {remote, for(file <- files, do: {file, upload(exe, dir, file, remote)})}
      end
    end
  end

  defp upload(exe, dir, file, remote) do
    path = Path.join(dir, file.path)

    case precheck(path, file) do
      :ok ->
        # Mirrors the script's `rclone copy <file> <remote>/<subdir>`.
        subdir = file.path |> Path.dirname() |> Path.basename()
        cmd(exe, ["copy", path, "#{remote}/#{subdir}"])

      {:error, reason} ->
        {:refused, reason}
    end
  end

  defp precheck(path, %{sidecar?: true, entries: entries}),
    do: Checksum.check_sidecar(path, entries)

  defp precheck(path, file), do: Checksum.recheck(path, file[:sha256], file[:bytes])

  # The checksum sidecar of each stamp+kind among `artifacts`, with the lines
  # it must hold: `{name, sha256}` of that kind+stamp's files in part order,
  # from the digests recorded when they verified. Kept even when the file is not
  # on disk, so a missing sidecar is refused (`:enoent`) rather than skipped:
  # a part set without its sidecar off-site is one restore.sh refuses.
  defp expected_sidecars(artifacts) do
    artifacts
    |> Enum.flat_map(fn artifact ->
      case Artifact.parse_file(Path.basename(artifact.path)) do
        {:ok, %{kind: kind, stamp: stamp, part: part}} -> [{{kind, stamp}, {part || 0, artifact}}]
        :error -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {{kind, stamp}, _} -> {kind != :db, stamp} end)
    |> Enum.map(fn {{kind, stamp}, members} ->
      entries =
        members
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_part, artifact} -> {Path.basename(artifact.path), artifact[:sha256]} end)

      %{
        kind: Atom.to_string(kind),
        path: Path.join(Artifact.subdir(kind), Artifact.sidecar_name(kind, stamp)),
        sidecar?: true,
        entries: entries
      }
    end)
  end

  # Partials left behind by a job Oban's timeout killed, or a node that
  # restarted mid-dump. Nothing else reclaims them: the `else` cleanup in
  # `dump_database`/`MediaArchive` doesn't run when the process is killed,
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

  @work_dir_max_age_s 3 * 24 * 3600

  @doc false
  # `.work/<stamp>` directories older than three days (#2218): the newest of the
  # directory's and `state.json`'s mtime, since every state write touches both.
  # Three days is long enough to resume over a weekend and short enough that an
  # abandoned failed run's lists don't pile up. Only directories named like a
  # stamp are touched, and never one whose Run is `running` (or whose Run can't
  # be read: when unsure, keep). Best-effort; returns the stamps removed.
  # sobelow_skip ["Traversal.FileModule"]
  @spec sweep_work_dirs(Path.t(), integer()) :: [String.t()]
  def sweep_work_dirs(dir, now \\ System.os_time(:second)) do
    cutoff = now - @work_dir_max_age_s

    for path <- Path.wildcard(Path.join([dir, ".work", "*"])),
        stamp = Path.basename(path),
        WorkState.valid_stamp?(stamp),
        work_dir_mtime(path) < cutoff,
        not run_in_flight?(stamp),
        match?({:ok, _}, File.rm_rf(path)) do
      Logger.warning("Removing an abandoned backup work directory: #{stamp}")
      stamp
    end
  rescue
    error ->
      Logger.warning("Backup work directory sweep failed: #{inspect(error)}")
      []
  end

  defp work_dir_mtime(path) do
    [path, WorkState.file(path)]
    |> Enum.map(fn p ->
      case File.stat(p, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> 0
      end
    end)
    |> Enum.max()
  end

  defp run_in_flight?(stamp) do
    case Backups.get_run_by_stamp(stamp, actor: Backups.system(), authorize_with: :error) do
      {:ok, nil} -> false
      {:ok, %{status: :running}} -> true
      {:ok, _run} -> false
      {:error, _} -> true
    end
  end

  @sidecar ~r/\Akiln-(?:db|media)-(\d{8}-\d{6})\.sha256\z/

  # Deletes backups older than `keep_days`, matching the script's `prune`, and
  # returns the file names it removed (so their runs can say `pruned`).
  #
  # The files of one stamp are ONE set (#2218): the dump, the media parts (or
  # the legacy single archive) and the checksum sidecars. The set is aged by its
  # NEWEST member and deleted together, so a retention sweep never leaves a
  # media set with a hole in it, and never strips a fresh part set of its
  # checksums. An orphan (the parts of a failed run) or a gap set ages out the
  # same way. A `kiln-*` file that is none of these ages alone, as before.
  # `.partial` is skipped (it may be a concurrent run's work; swept elsewhere)
  # and `.work` is not under `db/` or `media/`.
  #
  # Best-effort and never fatal: failing a backup that succeeded because its
  # housekeeping didn't would be exactly backwards. A removal that fails stops
  # that set (its remaining members stay) rather than skipping on past it.
  @doc false
  @spec prune(Path.t()) :: [String.t()]
  # sobelow_skip ["Traversal.FileModule"]
  def prune(dir) do
    # `(keep_days + 1) * 86400`, not `keep_days * 86400`, to match the shell's
    # `find -mtime +N`: that deletes only files whose age in WHOLE days is
    # strictly greater than N, i.e. age >= (N+1) days. Off by one here meant a
    # 14-day-6-hour dump was kept by cron and deleted by the app.
    cutoff =
      DateTime.to_unix(
        DateTime.add(DateTime.utc_now(), -(Backups.keep_days() + 1) * 24 * 60 * 60, :second)
      )

    paths =
      for sub <- ["db", "media"],
          path <- Path.wildcard(Path.join([dir, sub, "kiln-*"])),
          not String.ends_with?(path, ".partial"),
          do: path

    paths
    |> Enum.group_by(&set_key/1)
    |> Enum.flat_map(fn {_key, members} -> prune_set(members, cutoff) end)
  rescue
    error ->
      Logger.warning("Backup prune failed (backup itself succeeded): #{inspect(error)}")
      []
  end

  defp set_key(path) do
    name = Path.basename(path)

    case Artifact.parse_file(name) do
      {:ok, %{stamp: stamp}} ->
        {:stamp, stamp}

      :error ->
        case Regex.run(@sidecar, name) do
          [_, stamp] -> {:stamp, stamp}
          nil -> {:file, path}
        end
    end
  end

  defp prune_set(members, cutoff) do
    mtimes =
      for path <- members,
          {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
          do: mtime

    if mtimes != [] and Enum.max(mtimes) < cutoff, do: remove_set(members), else: []
  end

  # Sidecars last, so a set that stops half-way still has its checksums.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_set(members) do
    members
    |> Enum.sort_by(&Regex.match?(@sidecar, Path.basename(&1)))
    |> Enum.reduce_while([], fn path, deleted ->
      if File.rm(path) == :ok,
        do: {:cont, [Path.basename(path) | deleted]},
        else: {:halt, deleted}
    end)
    |> Enum.reverse()
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

  # Every step in both `with`s returns `:ok`/`{:ok, _}` or `{:error, _}`, so
  # this is the only shape the `else` can see.
  defp fail({:error, reason}), do: {:error, reason}

  defp describe({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{output}"

  defp describe(reason), do: inspect(reason)
end
