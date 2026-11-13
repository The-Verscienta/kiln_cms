defmodule KilnCMS.Backups.Steps do
  @moduledoc """
  The bodies of a backup's steps (#2218), one per `KilnCMS.Backups.StepWorker`
  job: `start`, `dump`, then with a media directory `plan`, `archive` (one job
  per part) and `checksum`, then `prune`, `offsite` and `finish`.

  ## Which components (#2219)

  The start step settles what the backup covers: the components its job's
  args ask for (`"components"`; absent or nil is everything) that this
  deployment has (`KilnCMS.Backups.expected_components/0`: media only with a
  media directory), or, for a resume, the run's own. It writes them into
  `state.json` as `"components"`, and **every later step reads them there and
  nowhere else**: `dump` does nothing for a backup without `"db"`, and `plan`,
  `archive` and `checksum` do nothing for one without `"media"`, each moving
  the chain on to the next step that applies. So a retried start, a resume and
  a step reclaimed onto another node all route the same way. A fresh request
  for media on a deployment that has no media directory is refused as a
  `skipped` run, with the manifest left alone.

  Produces what `scripts/backup.sh` produces: same directory layout, same
  database dump name, `pg_dump` flags and verification, same manifest, and the
  same media parts: a library larger than `Backups.media_part_bytes/0` becomes
  several independent `kiln-media-<stamp>.partNN.tar.gz` parts
  (`KilnCMS.Backups.MediaArchive`, which the script mirrors), with `sha256`
  sidecars. See `KilnCMS.Backups` for why one shared format is a requirement
  rather than a nicety.

  ## Handing over between steps

  Each step reads `.work/<stamp>/state.json` (`KilnCMS.Backups.WorkState`),
  does its work, writes the state back (mandatory: a failed write retries the
  step), records progress on the Run (best-effort, outside the lock) and moves
  the chain on (`KilnCMS.Backups.Chain.advance/3`). The state write happens
  under the lock, in its transaction, and only while the step's lease still
  holds it (`Chain.while_holding/2`, #2538): a step that outlived its Cancel,
  on a node that missed the signal, can't overwrite the state a resume of the
  same stamp has written since. It stops there, writing nothing else. The work directory exists
  for every backup, database-only ones included, so any failed backup can be
  resumed. A step after `start` that finds no state (deleted, or another
  chain's) fails the backup without writing a manifest: it has nothing to say
  about the files, and must not overwrite a good manifest with nothing.

  ## Failing

  A step that fails is retried (`StepWorker`'s four attempts, 1/5/15 minutes
  apart) unless the failure is one a retry cannot fix: a part that changed
  between archive and checksum (D7), a file refused before its off-site copy
  (#2481), lost state. On the last attempt, or a failure of that kind, the
  backup fails: a failure manifest (when the state is there), the Run closed
  as failed, the lock released (promoting a queued request), and the job
  canceled with the reason.

  ## Nothing is a backup until it verifies

  Every artifact is written to `<name>.partial` and renamed only after it
  passes (`pg_restore --list` for a dump, `tar -tzf` for an archive part). An
  aborted or corrupt run leaves a `.partial` that nothing will ever mistake
  for a backup.

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
  (after rclone's own retries) is retried with the step. The work directory
  is kept until the off-site copy succeeds, so Resume retries it, rebuilding
  only a file that changed.
  """
  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.ExternalCommand

  alias KilnCMS.Backups.{
    Artifact,
    Chain,
    Checksum,
    DirId,
    Heartbeat,
    Importer,
    Lock,
    Manifest,
    MediaArchive,
    RcloneRemote,
    Recorder,
    Redact,
    Retention,
    WorkState
  }

  require Logger

  # A legacy `Worker` job still executing (an old node mid-deploy) runs the
  # whole pipeline without the lock: the start step waits for it, up to three
  # hours (180 × 60 s), longer than that job's own timeout.
  @legacy_snooze_s 60
  @legacy_max_snoozes 180

  @doc """
  Run the step `lease` names (`KilnCMS.Backups.Chain.begin_step/1`) for `job`.
  Returns what `c:Oban.Worker.perform/1` returns.
  """
  @spec perform(Chain.lease(), Oban.Job.t()) ::
          :ok | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}
  def perform(%{step: "start"} = lease, job), do: start(lease, job)

  def perform(lease, job) do
    work_dir = WorkState.path(Backups.dir(), lease.stamp)

    case WorkState.read(work_dir) do
      {:ok, state} ->
        if WorkState.chain(state) == lease.chain,
          do: run_step(lease, job, state),
          else: lost_state(lease, :foreign_state)

      {:error, :no_state} ->
        lost_state(lease, :no_state)
    end
  end

  @doc """
  The step `job` raised: retried like any failure, and terminal on the last
  attempt. Called by `StepWorker` with what it could rescue.
  """
  @spec crashed(Chain.lease(), Oban.Job.t(), term()) :: {:error, term()} | {:cancel, term()}
  def crashed(lease, job, reason) do
    work_dir = lease.stamp && WorkState.path(Backups.dir(), lease.stamp)

    {state, rec} =
      case work_dir && WorkState.read(work_dir) do
        {:ok, %{} = state} ->
          if WorkState.chain(state) == lease.chain,
            do: {state, Recorder.load(lease.stamp, lease.chain, state["rec"])},
            else: {nil, Recorder.from_run(lease.stamp, lease.chain)}

        _ ->
          {nil, Recorder.from_run(lease.stamp, lease.chain)}
      end

    if resume_never_reopened?(lease, job, state, rec),
      do: refuse_resume(lease, reason),
      else: retry_or_fail(context(lease, state), lease, job, state, rec, reason)
  end

  # A resume's start that crashed before it re-opened the run (#2539) has no
  # run of its own to fail: on its last attempt it is refused, visibly.
  defp resume_never_reopened?(lease, job, state, rec) do
    lease.resume != nil and state == nil and rec.run == nil and
      job.attempt >= job.max_attempts
  end

  defp context(lease, state) do
    dir = Backups.dir()
    state = state || %{}

    %{
      dir: dir,
      stamp: lease.stamp,
      chain: lease.chain,
      work_dir: lease.stamp && WorkState.path(dir, lease.stamp),
      media_dir: Backups.media_dir(),
      trigger: state["trigger"] || lease.trigger || "manual",
      started_at: parse_time(state["started_at"]),
      resume?: state["resume"] == true
    }
  end

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_), do: DateTime.utc_now()

  ## start

  defp start(lease, job) do
    cond do
      legacy_running?() ->
        if (job.meta["snoozed"] || 0) < @legacy_max_snoozes,
          do: {:snooze, @legacy_snooze_s},
          else: {:error, :legacy_backup_running}

      match?({:error, _}, Backups.availability()) ->
        {:error, reason} = Backups.availability()
        unavailable(lease, reason, job.args)

      lease.resume != nil ->
        start_resume(lease, job)

      true ->
        start_fresh(lease, job)
    end
  end

  defp legacy_running? do
    KilnCMS.Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == "KilnCMS.Backups.Worker" and j.state == "executing"
      )
    )
  end

  # NOT recorded as a failed backup. "This image has no pg_dump" is a fact
  # about the app, not about the backups — and cron may be backing this
  # deployment up perfectly from the host. Writing `ok: false` here would
  # overwrite cron's record of a SUCCESSFUL backup and turn the overview red.
  # The ATTEMPT is history (a `skipped` run); the manifest is not touched.
  #
  # The skipped run records what was asked for (#2219), not what this
  # deployment could have backed up.
  defp unavailable(lease, reason, args) do
    Logger.warning("Backup refused (#{reason}) — leaving the existing manifest untouched")

    if lease.resume == nil do
      requested = requested_components(args) || Backups.expected_components()

      Recorder.skip(
        lease.stamp,
        lease.trigger || "manual",
        DateTime.utc_now(),
        requested,
        "Refused: #{reason}",
        schedule_fields(args, requested)
      )

      refuse(lease, reason)
    else
      refuse_resume(lease, reason)
    end
  end

  # The start job's `"components"`, or nil (everything). Unknown names are
  # dropped; the request was validated before it was queued.
  defp requested_components(%{"components" => names}) when is_list(names),
    do: Enum.filter(Lock.components(), &(Atom.to_string(&1) in names))

  defp requested_components(_args), do: nil

  # A schedule's share of `components`, and which schedules asked (#2219).
  defp schedule_fields(args, components) do
    scheduled = for name <- List.wrap(args["scheduled"]), is_binary(name), do: name

    %{
      scheduled_components: Enum.filter(components, &(Atom.to_string(&1) in scheduled)),
      schedule_ids: for(id <- List.wrap(args["schedule_ids"]), is_binary(id), do: id)
    }
  end

  defp component_names(components), do: Enum.map(components, &Atom.to_string/1)

  # Nothing was started: no manifest, no Run write beyond what the caller did.
  defp refuse(lease, reason) do
    _ = Chain.release(lease)
    settled(lease, {:error, reason})
    {:cancel, reason}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp start_fresh(lease, job) do
    dir = Backups.dir()
    work_dir = WorkState.path(dir, lease.stamp)

    reconcile_stale_runs()
    sweep_stale_partials(dir)
    sweep_work_dirs(dir)

    case WorkState.read(work_dir) do
      # The start step retried after its state landed: carry on from it.
      {:ok, %{"chain" => chain} = state} when chain == lease.chain ->
        rec = Recorder.load(lease.stamp, lease.chain, state["rec"])
        conclude(context(lease, state), lease, job, {:next, "dump", nil, state, rec})

      _other ->
        # A leftover directory under this stamp is not this chain's: it must not
        # lend its frozen plan or recorded hashes to a backup that has nothing
        # to do with them.
        File.rm_rf(work_dir)

        case effective_components(job.args) do
          [] -> unavailable(lease, :no_media_dir, job.args)
          components -> open_fresh(lease, job, work_dir, components)
        end
    end
  end

  # What was asked for (everything when the args don't say) that this
  # deployment has: media only with a media directory.
  defp effective_components(args) do
    expected = Backups.expected_components()

    case requested_components(args) do
      nil -> expected
      requested -> Enum.filter(expected, &(&1 in requested))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp open_fresh(lease, job, work_dir, components) do
    trigger = lease.trigger || "manual"
    started_at = DateTime.utc_now()
    scheduled = schedule_fields(job.args, components)

    rec =
      lease.stamp
      |> Recorder.open(
        trigger,
        started_at,
        components,
        job.id,
        lease.chain,
        Map.put(scheduled, :dir_id, lease.dir_id)
      )
      |> Recorder.log(:info, "start", "Backup started (#{trigger})")
      |> log_components(components)
      |> log_queue(job.args)

    state =
      WorkState.new(lease.stamp, %{
        "chain" => lease.chain,
        "trigger" => trigger,
        "started_at" => DateTime.to_iso8601(started_at),
        "resume" => false,
        "dir_id" => lease.dir_id,
        "components" => component_names(components),
        "scheduled" => component_names(scheduled.scheduled_components),
        "schedule_ids" => scheduled.schedule_ids,
        "outputs" => [],
        "reused" => [],
        "offsite" => nil
      })

    ctx = context(lease, state)

    result =
      with :ok <- mkdir_private(Path.dirname(work_dir)),
           :ok <- mkdir_private(work_dir) do
        {:next, "dump", nil, state, rec}
      else
        {:error, reason} ->
          {:retry, reason, nil, Recorder.log(rec, :error, "start", describe(reason))}
      end

    conclude(ctx, lease, job, result)
  end

  # Said only when the backup leaves something out.
  defp log_components(rec, components) do
    if components == Backups.expected_components(),
      do: rec,
      else: Recorder.log(rec, :info, "start", "Backing up only: #{Enum.join(components, ", ")}")
  end

  # The stamp and `started_at` are the ORIGINAL run's; the trigger too (the
  # manifest says who started the backup, not who resumed it).
  defp start_resume(lease, job) do
    work_dir = WorkState.path(Backups.dir(), lease.stamp)

    case WorkState.read(work_dir) do
      {:ok, %{"chain" => chain} = state} when chain == lease.chain ->
        rec = Recorder.load(lease.stamp, lease.chain, state["rec"])
        conclude(context(lease, state), lease, job, {:next, "dump", nil, state, rec})

      _other ->
        # The work state is read BEFORE the run is re-opened (#2539): a resume
        # whose files aren't here is refused with the run as it was, and says
        # so on the row. The re-open comes before the sweeps below: they fail
        # `running` runs that went quiet, and this one was exactly that until
        # `Recorder.reopen/3` flipped it back.
        with :ok <- resumable_here(lease.stamp),
             {:ok, state} <- WorkState.read(work_dir),
             {:ok, %{run: run} = rec} <- reopen(lease) do
          dir = Backups.dir()
          reconcile_stale_runs()
          sweep_stale_partials(dir)
          sweep_work_dirs(dir)

          rec =
            rec
            |> Recorder.log(:info, "resume", "Backup resumed (#{run.trigger})")
            |> log_queue(job.args)

          state =
            Map.merge(state, %{
              "version" => 2,
              "chain" => lease.chain,
              "trigger" => run.trigger,
              "started_at" => DateTime.to_iso8601(run.started_at),
              "resume" => true,
              "dir_id" => lease.dir_id,
              "components" => component_names(run.components),
              "scheduled" => component_names(run.scheduled_components),
              "schedule_ids" => run.schedule_ids,
              "outputs" => [],
              "reused" => [],
              "offsite" => nil
            })

          conclude(context(lease, state), lease, job, {:next, "dump", nil, state, rec})
        else
          {:error, reason} -> refuse_resume(lease, reason)
        end
    end
  end

  # A resume that can't run here (#2539) closes visibly: the run says why on
  # its row before the lock is released, as `fail/5` does, so a Resume can't
  # re-open a run this chain is still about to write. Nothing was started: no
  # manifest.
  defp refuse_resume(lease, reason) do
    Logger.warning("Backup resume refused: #{inspect(reason)}")
    note_resume_refused(lease.resume, lease.chain, reason)
    _ = Chain.release(lease)
    settled(lease, {:error, reason})
    {:cancel, reason}
  end

  @doc false
  # A resume chain given up from outside its start step (#2539): the start
  # never found a node with the run's files (`Chain.abandon_start/2`), or it
  # was interrupted before it re-opened the run (`Chain`'s reap and reclaim).
  # The caller has released the lock. The run says why, and the chain settles.
  @spec resume_refused(String.t(), String.t(), term()) :: :ok
  def resume_refused(stamp, chain, reason) do
    Logger.warning("Backup resume of #{stamp} refused: #{inspect(reason)}")
    note_resume_refused(stamp, chain, reason)
    settled(%{chain: chain, stamp: stamp}, {:error, reason})
  end

  # A run this chain re-opened (an attempt got that far, then lost its files)
  # is ours: failed with the reason, and resumable again. Any other run never
  # was ours, so it keeps its status and gains the note (`Recorder.resume_refused/2`).
  defp note_resume_refused(stamp, chain, reason) do
    message = describe_resume_refusal(reason, stamp)

    case Recorder.reopened(stamp, chain) do
      {:ok, rec} ->
        rec
        |> Recorder.log(:error, "resume", "Resume refused: " <> message)
        |> Recorder.fail("Resume refused: " <> message)

      {:error, _} ->
        Recorder.resume_refused(stamp, message)
    end

    :ok
  end

  defp describe_resume_refusal(:no_state, stamp),
    do: "its work files (.work/#{stamp}/state.json) are not on the server that picked it up"

  defp describe_resume_refusal(:no_media_dir, _stamp),
    do: "it backs up only media, and the server that picked it up has no media directory"

  defp describe_resume_refusal({:not_resumable, _status}, _stamp),
    do: "the run changed meanwhile"

  defp describe_resume_refusal(:not_resumable, _stamp), do: "the run changed meanwhile"

  defp describe_resume_refusal({:backup_dir_elsewhere, id}, _stamp),
    do:
      "no server with its backup directory (id #{id}) picked it up; " <>
        "every attempt waited about 10 minutes for one"

  defp describe_resume_refusal({:canceled_recently, _seconds}, _stamp),
    do: "it was canceled moments ago and the wait ran out"

  defp describe_resume_refusal(reason, _stamp)
       when reason in [:disabled, :no_database_url, :no_pg_dump, :no_pg_restore],
       do: "backups are not available on the server that picked it up (#{reason})"

  defp describe_resume_refusal({:interrupted, message}, _stamp), do: message

  defp describe_resume_refusal({:crashed, message}, _stamp),
    do: "its start step crashed: #{message}"

  defp describe_resume_refusal(reason, _stamp), do: inspect(reason)

  # A resume backs up what its run did (#2219). A run of nothing but media,
  # resumed on a node with no media directory, would have nothing to do:
  # refused before the run is re-opened.
  defp resumable_here(stamp) do
    case Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
      {:ok, %{components: components}} when components != [] ->
        if Enum.any?(components, &(&1 in Backups.expected_components())),
          do: :ok,
          else: {:error, :no_media_dir}

      _other ->
        :ok
    end
  end

  # An earlier attempt of this start step may have re-opened the Run already
  # and then failed (its state write, say): the Run is `running` under this
  # chain, which `resumable_run/3` refuses as not resumable. That one is ours
  # to carry on with.
  #
  # Either way the run is bound to this node's backup directory (#2539), which
  # just read the run's `state.json`: `Recorder.reopen/3` writes it, and a run
  # already re-opened records it with its next progress write.
  defp reopen(lease) do
    case Recorder.reopened(lease.stamp, lease.chain) do
      {:ok, rec} ->
        {:ok, %{rec | dir_id: lease.dir_id}}

      {:error, _} ->
        with {:ok, run, waited_ms} <- settled_resumable(lease.stamp, 0),
             {:ok, rec} <- Recorder.reopen(run.stamp, lease.chain, lease.dir_id) do
          {:ok, log_settle_wait(rec, waited_ms)}
        end
    end
  end

  # A resume start that reaches a run canceled moments ago (#2538) waits out
  # the rest of `Heartbeat.settled_after_ms/0` here, in the step, rather than
  # refusing. Only a start the request path didn't check gets here: a queued
  # resume promoted by the Cancel itself, or a start retried or reclaimed
  # inside the window. The chain holds the lock, so nothing else runs
  # meanwhile, and the wait is bounded far below the step's timeout.
  #
  # Not a snooze: Oban's snooze ack rewrites `meta` from the job it fetched
  # (`Oban.Engines.Basic`), so this start couldn't move `affinity_base` past
  # its own snoozes, and they would count against the attempt's affinity
  # budget (`StepWorker`).
  defp settled_resumable(stamp, waited_ms) do
    case Backups.resumable_run(stamp, DateTime.utc_now(), lock: false) do
      {:ok, run} ->
        {:ok, run, waited_ms}

      {:error, {:canceled_recently, seconds}} = refused ->
        left_ms = Heartbeat.settled_after_ms() + 30_000 - waited_ms

        if left_ms > 0 do
          nap_ms = seconds |> min(30) |> Kernel.*(1000) |> min(left_ms)

          Logger.info(
            "Backup resume of #{stamp} waits #{seconds} s: it was canceled moments ago, " <>
              "and a step on a node that lost the database may still be stopping"
          )

          Process.sleep(nap_ms)
          settled_resumable(stamp, waited_ms + nap_ms)
        else
          refused
        end

      {:error, _} = refused ->
        refused
    end
  end

  defp log_settle_wait(rec, 0), do: rec

  defp log_settle_wait(rec, waited_ms) do
    Recorder.log(
      rec,
      :info,
      "resume",
      "Waited #{div(waited_ms + 999, 1000)} s after the Cancel before resuming"
    )
  end

  # A promoted request says where it came from.
  defp log_queue(rec, %{"requested_at" => at} = args) when is_binary(at) do
    folded =
      case args["folded"] do
        n when is_integer(n) and n > 0 -> "; #{n} later request(s) folded into it"
        _ -> ""
      end

    Recorder.log(rec, :info, "start", "Started from the queue (requested at #{at})#{folded}")
  end

  defp log_queue(rec, _args), do: rec

  ## The steps after start

  defp run_step(lease, job, state) do
    ctx = context(lease, state)
    rec = Recorder.load(lease.stamp, lease.chain, state["rec"])

    result =
      case lease.step do
        "dump" -> dump_step(ctx, state, rec)
        "plan" -> plan_step(ctx, state, rec)
        "archive" -> archive_step(ctx, lease.part, state, rec)
        "checksum" -> checksum_step(ctx, state, rec)
        "prune" -> prune_step(ctx, state, rec)
        "offsite" -> offsite_chain_step(ctx, state, rec)
        "finish" -> finish_step(ctx, lease, state, rec)
      end

    conclude(ctx, lease, job, result)
  end

  # Gone or not ours: nothing to vouch for, so no manifest (a good one may be
  # there), and the run is closed from what its row already holds.
  defp lost_state(lease, reason) do
    error =
      "The backup's work state (.work/#{lease.stamp}/state.json) is missing or belongs to " <>
        "another backup; nothing more can be done for this one"

    Logger.error("Backup FAILED: #{error}")

    lease.stamp
    |> Recorder.from_run(lease.chain)
    |> Recorder.log(:error, lease.step, error)
    |> Recorder.fail(error)

    _ = Chain.release(lease)
    settled(lease, {:error, reason})
    {:cancel, reason}
  end

  # The state write is fenced (#2538): it runs under the lock, and only while
  # this step's lease still holds it. A step that outlived its Cancel (its node
  # missed the signal) must not overwrite the `state.json` a resume of the same
  # stamp has since written; it stops here, with no Run write and no advance.
  defp conclude(ctx, lease, job, {:next, step, part, state, rec}) do
    state = Map.put(state, "rec", Recorder.to_state(rec))

    case Chain.while_holding(lease, fn -> WorkState.write(ctx.work_dir, state) end) do
      {:ok, :ok} ->
        # Best-effort, and outside the lock: a failed Run write costs history,
        # never the backup.
        _ = Recorder.progress(rec)

        case Chain.advance(lease, step, part) do
          :ok -> :ok
          {:error, :superseded} -> {:cancel, :superseded}
          {:error, reason} -> retry_or_fail(ctx, lease, job, state, rec, reason)
        end

      {:ok, {:error, reason}} ->
        retry_or_fail(ctx, lease, job, state, rec, {:state_write, reason})

      {:error, :superseded} ->
        {:cancel, :superseded}
    end
  end

  defp conclude(ctx, lease, job, {:retry, reason, state, rec}),
    do: retry_or_fail(ctx, lease, job, state, rec, reason)

  defp conclude(ctx, lease, _job, {:fatal, reason, state, rec}),
    do: fail(ctx, lease, state, rec, reason)

  defp conclude(_ctx, _lease, _job, {:result, result}), do: result

  # Oban's attempt counter decides: the last attempt (`attempt >= max_attempts`,
  # which also covers a reclaimed step's reduced budget) fails the backup.
  defp retry_or_fail(ctx, lease, job, state, rec, reason) do
    if job.attempt >= job.max_attempts do
      fail(ctx, lease, state, rec, reason)
    else
      Logger.warning(
        "Backup step #{lease.step} failed (attempt #{job.attempt} of #{job.max_attempts}), " <>
          "retrying: #{inspect(reason)}"
      )

      # Keep the attempt's log lines for the next one; best-effort, but fenced
      # like `conclude/4`'s write: a superseded step writes nothing more.
      case keep_log(ctx, lease, state, rec) do
        {:error, :superseded} ->
          {:cancel, :superseded}

        _written_or_not ->
          _ = Recorder.progress(rec)
          {:error, reason}
      end
    end
  end

  defp keep_log(ctx, lease, state, rec) do
    if state && ctx.work_dir do
      Chain.while_holding(lease, fn ->
        WorkState.write(ctx.work_dir, Map.put(state, "rec", Recorder.to_state(rec)))
      end)
    else
      {:ok, :ok}
    end
  end

  # The backup is over. A failure manifest only when the state is there to say
  # what landed; the Run closed BEFORE the lock is released, so a Resume can
  # never re-open a run this chain is still about to write.
  defp fail(ctx, lease, state, rec, reason) do
    Logger.error("Backup FAILED (#{ctx.trigger}): #{inspect(reason)}")
    error = describe_failure(reason)

    # Under the lock, and only while this chain still holds it: a Cancel that
    # committed first (decision 4: no manifest on cancel) or a reclaim that
    # superseded this job leaves the previous manifest standing.
    if state && ctx.work_dir && WorkState.exists?(ctx.work_dir) do
      partial = state |> outputs() |> unverify(reason)

      _ =
        Chain.while_holding(lease, fn ->
          record_failure(
            ctx.dir,
            ctx.stamp,
            ctx.trigger,
            ctx.started_at,
            error,
            partial,
            components(state)
          )
        end)
    end

    Recorder.fail(rec, error)

    # Last, so a cron-made backup sitting next to this one is picked up too.
    # The importer is total; nothing it does changes the backup's outcome.
    _ = Importer.run()
    _ = Chain.release(lease)
    settled(lease, {:error, reason})
    {:cancel, reason}
  end

  defp describe_failure({:offsite, _} = reason), do: describe_offsite(reason, true)

  defp describe_failure({:checksum_changed, names}),
    do:
      "Media part(s) changed on disk between being archived and being checksummed: " <>
        Enum.join(names, ", ") <>
        ". Something other than this backup wrote to the backup directory; Resume rebuilds " <>
        "the changed part(s)."

  defp describe_failure(reason), do: describe(reason)

  @doc """
  Record a chain that was interrupted from outside (its node stopped, its job
  ended without finishing): fail its Run with `message` and, when this node
  has the chain's backup directory and its state, write the failure manifest.
  Best-effort throughout.
  """
  @spec interrupt(String.t(), String.t(), String.t() | nil, String.t()) :: :ok
  def interrupt(stamp, chain, dir_id, message) do
    dir = Backups.dir()
    work_dir = WorkState.path(dir, stamp)

    here? = dir_id != nil and DirId.current(dir) == {:ok, dir_id}

    rec =
      with true <- here?,
           {:ok, %{"chain" => ^chain} = state} <- WorkState.read(work_dir) do
        record_failure(
          dir,
          stamp,
          state["trigger"] || "manual",
          parse_time(state["started_at"]),
          message,
          outputs(state),
          components(state)
        )

        Recorder.load(stamp, chain, state["rec"])
      else
        _ -> Recorder.from_run(stamp, chain)
      end

    rec |> Recorder.log(:error, "interrupt", message) |> Recorder.fail(message)
    :ok
  end

  @doc false
  # The chain settled; tests and `Backups.await/2` listen for this.
  @spec settled(map(), :ok | {:error, term()}) :: :ok
  def settled(lease, outcome) do
    :telemetry.execute([:kiln_cms, :backups, :chain, :settled], %{count: 1}, %{
      chain: lease.chain,
      stamp: lease.stamp,
      outcome: outcome
    })
  end

  defp outputs(nil), do: []

  defp outputs(state) do
    for entry <- List.wrap(state["outputs"]), is_map(entry) do
      for {key, value} <- entry, into: %{}, do: {String.to_existing_atom(to_string(key)), value}
    end
  end

  defp put_outputs(state, entries),
    do: Map.put(state, "outputs", Enum.map(outputs(state) ++ entries, &stringify/1))

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # The components `state.json` names (#2219); a state without the key, from
  # before components existed, covers everything.
  defp components(state) do
    case state["components"] do
      names when is_list(names) -> names
      _ -> ["db", "media"]
    end
  end

  defp db?(state), do: "db" in components(state)
  defp media?(ctx, state), do: ctx.media_dir != nil and "media" in components(state)

  # What a finished backup covered: media only where there was a media
  # directory to archive (a resume on a node without one backs up the rest).
  defp covered(ctx, state),
    do: Enum.filter(components(state), &(&1 == "db" or media?(ctx, state)))

  # Where the chain goes after the database dump: the media steps, or prune.
  defp after_dump(ctx, state), do: if(media?(ctx, state), do: "plan", else: "prune")

  # A revoked grant raises there; this is a job tail, so it is a warning.
  defp reconcile_stale_runs do
    Backups.reconcile_stale_runs()
  rescue
    error ->
      Logger.warning("Couldn't sweep stale backup runs: #{Exception.message(error)}")
      0
  end

  ## dump

  # A backup without the database skips the dump (#2219).
  defp dump_step(ctx, state, rec) do
    if db?(state),
      do: dump_db(ctx, state, rec, after_dump(ctx, state)),
      else: {:next, after_dump(ctx, state), nil, state, rec}
  end

  defp dump_db(ctx, state, rec, next) do
    case reuse_dump(ctx, state) do
      {:ok, db, at} ->
        rec =
          rec
          |> Recorder.add_artifact(db)
          |> Recorder.log(
            :info,
            "dump",
            "Database dump reused from the original attempt (written #{at}); sha256 re-verified (#{db.bytes} bytes)"
          )

        {:next, next, nil, put_outputs(state, [db]), rec}

      :build ->
        case dump_database(ctx.dir, ctx.stamp) do
          {:ok, db} ->
            state =
              state
              |> WorkState.put_dump(%{
                name: Path.basename(db.path),
                bytes: db.bytes,
                sha256: db.sha256
              })
              |> WorkState.complete("dump")
              |> put_outputs([db])

            rec =
              rec
              |> Recorder.add_artifact(db)
              |> Recorder.log(:info, "dump", "Database dump verified (#{db.bytes} bytes)")

            {:next, next, nil, state, rec}

          {:error, reason} ->
            {:retry, reason, state, Recorder.log(rec, :error, "dump", describe(reason))}
        end
    end
  end

  # A dump is reused only if `state.json` recorded its digest AND the file on
  # disk still hashes to it (and has the recorded size). The name is rebuilt
  # from the stamp, never taken from the file. The state is this chain's (a
  # retry) or the resumed run's.
  # sobelow_skip ["Traversal.FileModule"]
  defp reuse_dump(ctx, state) do
    name = "kiln-db-#{ctx.stamp}.dump"
    target = Path.join([ctx.dir, "db", name])

    with %{"name" => ^name, "bytes" => bytes, "sha256" => sha256} = entry <-
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

  ## plan

  # A backup without media (or a node without the media directory) skips the
  # media steps (#2219).
  defp plan_step(ctx, state, rec) do
    if media?(ctx, state),
      do: plan_media(ctx, state, rec),
      else: {:next, "prune", nil, state, rec}
  end

  # The plan is frozen at first creation. A later step or a resume loads it;
  # only if it is gone (planning never finished) is it made afresh, and then
  # nothing recorded for the old partition means anything: the recorded parts
  # are forgotten and the files of an earlier set under this stamp removed, so
  # a leftover `part04` cannot sit beside a new three-part set.
  defp plan_media(ctx, state, rec) do
    target_dir = Path.join(ctx.dir, "media")

    result =
      case MediaArchive.load_plan(ctx.media_dir, ctx.work_dir) do
        {:ok, plan} when ctx.resume? ->
          {:ok, plan, state,
           Recorder.log(
             rec,
             :info,
             "media",
             "Reusing the frozen plan: #{plan.files} file(s) in #{length(plan.parts)} part(s)"
           )}

        {:ok, plan} ->
          {:ok, plan, state, log_plan(rec, plan)}

        {:error, :no_plan} ->
          discard_media_files(target_dir, ctx.stamp)
          state = WorkState.clear_parts(state)

          with {:ok, plan} <- MediaArchive.plan(ctx.media_dir, ctx.work_dir, stamp: ctx.stamp) do
            {:ok, plan, state, log_plan(rec, plan)}
          end
      end

    case result do
      {:ok, plan, state, rec} ->
        state =
          state
          |> WorkState.complete("plan")
          |> Map.put("parts_total", length(plan.parts))
          |> Map.put("reused", [])

        {:next, "archive", 1, state, rec}

      {:error, reason} ->
        {:retry, reason, state, Recorder.log(rec, :error, "media", describe(reason))}
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

  defp load_plan(ctx) do
    case MediaArchive.load_plan(ctx.media_dir, ctx.work_dir) do
      {:ok, plan} -> {:ok, plan}
      {:error, :no_plan} -> {:error, :plan_lost}
    end
  end

  ## archive (one part per job)

  # The state is written and the Run touched after EACH part: that is what
  # makes a resume skip the finished ones, and what keeps a long archive from
  # looking stale.
  defp archive_step(ctx, index, state, rec) do
    if media?(ctx, state),
      do: archive_media(ctx, index, state, rec),
      else: {:next, "prune", nil, state, rec}
  end

  defp archive_media(ctx, index, state, rec) do
    target_dir = Path.join(ctx.dir, "media")

    with {:ok, plan} <- load_plan(ctx),
         %{} = part <- Enum.at(plan.parts, index - 1) do
      total = length(plan.parts)

      case reuse_part(ctx, plan, part, target_dir, state) do
        {:ok, _finished, at} ->
          state = Map.update(state, "reused", [[index, at]], &(&1 ++ [[index, at]]))
          next_part(state, rec, index, total)

        :build ->
          build_part(plan, part, target_dir, {index, total}, state, rec)
      end
    else
      _lost -> {:fatal, :plan_lost, state, rec}
    end
  end

  defp build_part(plan, part, target_dir, {index, total}, state, rec) do
    case MediaArchive.archive_part(plan, part.index, target_dir) do
      {:ok, finished} ->
        state = WorkState.put_part(state, finished)
        next_part(state, log_dropped(rec, [finished]), index, total)

      {:error, reason} ->
        {:retry, reason, state, Recorder.log(rec, :error, "media", describe(reason))}
    end
  end

  defp next_part(state, rec, index, total) when index < total,
    do: {:next, "archive", index + 1, state, rec}

  defp next_part(state, rec, _index, total) do
    reused = List.wrap(state["reused"])
    {:next, "checksum", nil, WorkState.complete(state, "archive"), log_reused(rec, reused, total)}
  end

  # A part is reused only if `state.json` recorded its digest AND the file in
  # the media directory still hashes to it with the recorded size. The name
  # comes from the frozen plan, not from the state file.
  defp reuse_part(_ctx, plan, part, target_dir, state) do
    name = plan |> MediaArchive.names() |> Enum.at(part.index - 1)
    path = Path.join(target_dir, name)

    with %{"name" => ^name, "bytes" => bytes, "sha256" => sha256} = entry <-
           WorkState.part(state, part.index),
         # The off-site gate's own check, so a file reused here is one the
         # upload will accept (a symlink is rebuilt, never reused).
         :ok <- Checksum.recheck(path, sha256, bytes) do
      {:ok, finished(part, entry, path), entry["at"]}
    else
      _ -> :build
    end
  end

  defp finished(part, entry, path) do
    %{
      index: part.index,
      name: entry["name"],
      path: path,
      bytes: entry["bytes"],
      sha256: entry["sha256"],
      oversize: part.oversize,
      files: entry["files"] || part.files,
      dropped: 0,
      verified: true
    }
  end

  # The set now mixes times: say so on the Run.
  defp log_reused(rec, [], _total), do: rec

  defp log_reused(rec, reused, total) do
    indexes = Enum.map_join(reused, ", ", &hd/1)

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

  ## checksum

  # A part that changed since it was archived fails the backup (D7): not
  # retried, and not rebuilt in this run. Resume rebuilds it (its recorded
  # hash no longer matches).
  defp checksum_step(ctx, state, rec) do
    if media?(ctx, state),
      do: checksum_media(ctx, state, rec),
      else: {:next, "prune", nil, state, rec}
  end

  defp checksum_media(ctx, state, rec) do
    target_dir = Path.join(ctx.dir, "media")

    with {:ok, plan} <- load_plan(ctx),
         {:ok, parts} <- recorded_parts(plan, state, target_dir) do
      case MediaArchive.checksum(plan, parts, target_dir) do
        {:ok, set} ->
          state =
            state
            |> WorkState.complete("checksum")
            |> put_outputs(media_entries(parts))

          {:next, "prune", nil, state, record_media(rec, parts, set)}

        {:error, {:checksum_changed, names} = reason} ->
          rec =
            Recorder.log(
              rec,
              :error,
              "media",
              "Changed after being archived: #{Enum.join(names, ", ")}"
            )

          {:fatal, reason, state, rec}

        {:error, reason} ->
          {:retry, reason, state, Recorder.log(rec, :error, "media", describe(reason))}
      end
    else
      {:error, reason} -> {:fatal, reason, state, rec}
    end
  end

  defp recorded_parts(plan, state, target_dir) do
    names = MediaArchive.names(plan)

    parts =
      for {part, name} <- Enum.zip(plan.parts, names),
          %{"name" => ^name} = entry <- [WorkState.part(state, part.index)],
          do: finished(part, entry, Path.join(target_dir, name))

    if length(parts) == length(plan.parts), do: {:ok, parts}, else: {:error, :parts_lost}
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

    Recorder.log(
      %{rec | artifacts: rec.artifacts ++ attrs},
      :info,
      "media",
      "Media archive verified (#{length(parts)} part(s), #{bytes} bytes)"
    )
  end

  ## prune

  # Before the off-site copy, as it always ran (#2481): this run's
  # `.work/<stamp>` exists, so `Retention` counts it in flight and never
  # touches it. A retention that can't see the backup history deletes nothing
  # and says so on the run; the backup's own outcome does not change.
  defp prune_step(ctx, state, rec) do
    rec =
      case Retention.run(ctx.dir) do
        {:ok, %{deleted: [], stopped: nil}} ->
          rec

        {:ok, %{deleted: names, units: units, stopped: nil}} ->
          Recorder.log(rec, :info, "prune", removed(names, units))

        {:ok, %{deleted: names, units: units, stopped: reason}} ->
          Recorder.log(
            rec,
            :error,
            "prune",
            removed(names, units) <> ", then stopped: #{Retention.describe(reason)}"
          )

        {:error, reason} ->
          Recorder.log(
            rec,
            :error,
            "prune",
            "Retention skipped: #{Retention.describe(reason)}; nothing was deleted"
          )
      end

    {:next, "offsite", nil, state, rec}
  end

  defp removed(names, units),
    do: "Retention removed #{length(names)} file(s) from #{units} backup(s)"

  ## offsite

  # A refused file is fatal (never retried, #2481); so is a missing rclone,
  # which no retry installs (#2482). A failed copy is retried with the step,
  # and fails the backup on the last attempt.
  defp offsite_chain_step(ctx, state, rec) do
    case offsite_step(ctx.dir, outputs(state), rec) do
      {:ok, remote, rec} ->
        {:next, "finish", nil, Map.put(state, "offsite", remote), rec}

      {:error, {:offsite, %{refused: [_ | _]}} = reason, rec} ->
        {:fatal, reason, state, rec}

      {:error, {:offsite, :missing_rclone} = reason, rec} ->
        {:fatal, reason, state, rec}

      {:error, reason, rec} ->
        {:retry, reason, state, rec}
    end
  end

  ## finish

  defp finish_step(ctx, lease, state, rec) do
    case Chain.mark_finishing(lease) do
      :ok ->
        {:result, succeed(ctx, lease, state, rec)}

      {:error, :superseded} ->
        {:result, {:cancel, :superseded}}

      {:error, reason} ->
        {:retry, reason, state, rec}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp succeed(ctx, lease, state, rec) do
    artifacts = outputs(state)
    offsite = state["offsite"]

    # The manifest FIRST: it has no database dependency, and cron-era
    # consumers read it. The run is closed after. On a resume this
    # overwrites the failed run's manifest with `ok: true` (atomic rename).
    write_manifest(ctx.dir, %Manifest{
      stamp: ctx.stamp,
      started_at: ctx.started_at,
      finished_at: DateTime.utc_now(),
      trigger: ctx.trigger,
      ok: true,
      components: covered(ctx, state),
      artifacts: artifacts,
      offsite: offsite && Redact.text(offsite),
      keep_days: Backups.keep_days()
    })

    rec
    |> Recorder.log(:info, "done", "Backup complete: #{length(artifacts)} artifact(s)")
    |> Recorder.finish()

    # After the run is closed: a node that dies between the two leaves at most
    # a stale `.work/<stamp>`, which `sweep_work_dirs/2` removes in time.
    File.rm_rf(ctx.work_dir)

    # Once `.work/<stamp>` is gone this run is no longer in flight, so it can
    # be the newest verified backup: its `.good` markers are written now,
    # under the lock, so a later run that fails leaving a newer complete set
    # can't get the cron prune to take this one. Total; nothing it does
    # changes the backup's outcome. It runs the importer first, so a
    # cron-made backup sitting next to this one is picked up too.
    _ = Retention.sync_last_good(ctx.dir)
    _ = Chain.release(lease)

    Logger.info(
      "Backup complete (#{ctx.trigger}): #{length(artifacts)} artifact(s) in #{ctx.dir}"
    )

    settled(lease, :ok)
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

  defp unverify(artifacts, _reason), do: artifacts

  ## Off-site copy

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
  # A remote set with no `rclone` in this image is a failed copy like any
  # other (#2482): `{:error, {:offsite, :missing_rclone}, rec}`, before any
  # file is touched. The official image ships rclone, so only a custom image
  # without it gets here. The reason carries no remote: `fail/5` logs
  # `inspect(reason)`, and a connection-string remote holds credentials.
  @missing_rclone "BACKUP_RCLONE_REMOTE is set but rclone is not installed in this image"

  @doc false
  @spec offsite_step(Path.t(), [map()], Recorder.t()) ::
          {:ok, String.t() | nil, Recorder.t()} | {:error, term(), Recorder.t()}
  def offsite_step(dir, artifacts, rec) do
    case offsite_results(dir, artifacts) do
      nil ->
        {:ok, nil, rec}

      {:missing_rclone, remote} ->
        message = @missing_rclone <> "; nothing was copied off-site"
        Logger.error(message <> " (#{Redact.text(remote)})")
        {:error, {:offsite, :missing_rclone}, Recorder.log(rec, :error, "offsite", message)}

      {remote, results} ->
        key = "rclone:" <> Redact.text(remote)
        rec = Enum.reduce(results, rec, &record_offsite(&1, &2, key))

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
  def describe_offsite({:offsite, :missing_rclone}, resumable?) do
    "Off-site copy FAILED: #{@missing_rclone}, so no file was copied. The local files are " <>
      "kept. Install rclone in the image (the official image ships it) or unset " <>
      "BACKUP_RCLONE_REMOTE, then " <>
      if(resumable?, do: "Resume this backup.", else: "run a new backup.")
  end

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

  @doc """
  Copies fresh artifacts to the configured rclone remote, returning the remote
  it used or `nil`: the remote only when every file, sidecars included, was
  re-verified and copied; `nil` when there is no remote, no `rclone`, or any
  file was refused or failed. `offsite_step/3` is what the chain runs: it
  records each file's outcome and fails the step on any of them.
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
          # A connection-string remote's parameters go to rclone as
          # `RCLONE_CONFIG_*` variables, never as an argument (#2690).
          target = RcloneRemote.split_credentials(remote)
          {remote, for(file <- files, do: {file, upload(exe, dir, file, target)})}
      end
    end
  end

  defp upload(exe, dir, file, {remote, env}) do
    path = Path.join(dir, file.path)

    case precheck(path, file) do
      :ok ->
        # Mirrors the script's `rclone copy <file> <remote>/<subdir>`.
        subdir = file.path |> Path.dirname() |> Path.basename()
        cmd(exe, ["copy", path, "#{remote}/#{subdir}"], env)

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

  ## The database dump

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
        fail_tuple(error)
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
        fail_tuple(error)
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

    # Relative to the backup directory, so the manifest survives the
    # directory being moved or read from another mount.
    %{
      kind: kind,
      path: Path.relative_to(target, dir),
      bytes: hashed,
      verified: size == hashed and is_binary(sha256),
      sha256: sha256
    }
  end

  ## Sweeps

  # Partials left behind by a job Oban's timeout killed, or a node that
  # restarted mid-dump. Nothing else reclaims them: the `else` cleanup in
  # `dump_database`/`MediaArchive` doesn't run when the process is killed,
  # and retention deliberately skips `.partial` so it can't delete a
  # CONCURRENT run's work. An hour's grace makes that distinction. Run only by
  # the start step, which holds the lock, so no other chain is writing.
  #
  # Each of these is potentially a full-database-sized file, so leaving them
  # is how a backup directory fills a disk.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_stale_partials(dir) do
    cutoff = System.os_time(:second) - Retention.partial_grace_s()

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
  # be read: when unsure, keep), nor the one the lock holds (and none at all
  # when the lock can't be read: when unsure, keep). Best-effort; returns the
  # stamps removed.
  # sobelow_skip ["Traversal.FileModule"]
  @spec sweep_work_dirs(Path.t(), integer()) :: [String.t()]
  def sweep_work_dirs(dir, now \\ System.os_time(:second)) do
    case Chain.fetch_held_stamp() do
      {:ok, held} ->
        sweep_work_dirs(dir, now, held)

      {:error, error} ->
        Logger.warning(
          "Backup work directory sweep skipped: the lock can't be read: #{inspect(error)}"
        )

        []
    end
  rescue
    error ->
      Logger.warning("Backup work directory sweep failed: #{inspect(error)}")
      []
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_work_dirs(dir, now, held) do
    cutoff = now - @work_dir_max_age_s

    for path <- Path.wildcard(Path.join([dir, ".work", "*"])),
        stamp = Path.basename(path),
        WorkState.valid_stamp?(stamp),
        stamp != held,
        work_dir_mtime(path) < cutoff,
        not run_in_flight?(stamp),
        match?({:ok, _}, File.rm_rf(path)) do
      Logger.warning("Removing an abandoned backup work directory: #{stamp}")
      stamp
    end
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

  ## Manifest

  # A run that STARTED and failed writes a manifest. Leaving the previous,
  # successful one in place would tell an admin the last backup was fine —
  # true, and not the question they are asking.
  #
  # `partial` carries whatever genuinely landed and verified before the
  # failure, so a media error doesn't hide a perfectly good database dump.
  #
  # `stamp` is the run's, written so the importer keys this manifest by it: the
  # stamp is taken at lease time and `started_at` a moment later, so the
  # second of `started_at` is not always the run's (a duplicate failed run).
  defp record_failure(dir, stamp, trigger, started_at, error, partial, components) do
    write_manifest(dir, %Manifest{
      stamp: stamp,
      started_at: started_at,
      finished_at: DateTime.utc_now(),
      trigger: trigger,
      ok: false,
      components: components,
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

  ## External commands

  # An argv list exec'd directly — no shell, so nothing here can be injected
  # into even though the database URL carries a password.
  #
  # `ExternalCommand`, not `System.cmd/3`: a job killed mid-run (timeout,
  # cancel, a fenced node) must take `pg_dump`/`rclone` down with it rather
  # than leave it writing a `.partial` a retry collides with. No wall-clock
  # bound of its own; the job's timeout is the bound.
  #
  # stderr is captured rather than inherited so a failure can be reported with
  # its actual reason. It is NOT logged verbatim: `pg_dump`'s error output can
  # echo the connection string, and a backup failure should not put the
  # database password in the log.
  defp cmd(executable, args, env \\ []) do
    # `rclone` arrives as an absolute path, `pg_dump`/`pg_restore` by name;
    # `System.find_executable/1` resolves both (`:spawn_executable` searches
    # no `PATH`).
    case System.find_executable(executable) do
      nil ->
        {:error, {executable, :enoent}}

      exe ->
        case ExternalCommand.run(exe, args, :infinity, env: env) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:exit_status, executable, status, redact(output, env)}}
        end
    end
  end

  @doc """
  Splits a connection URL into a password-free URL plus a `PGPASSWORD`
  environment entry.

  The password must not be an **argv** element. There is no injection risk
  (no shell) — but argv is not private: `/proc/<pid>/cmdline` is
  world-readable (0444, unlike `environ`'s 0400), the host's `ps` shows a
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
  defp fail_tuple({:error, reason}), do: {:error, reason}

  defp describe({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{output}"

  defp describe(reason), do: inspect(reason)
end
