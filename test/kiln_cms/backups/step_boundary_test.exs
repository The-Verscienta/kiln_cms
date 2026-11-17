defmodule KilnCMS.Backups.StepBoundaryTest.SupersedingImporter do
  @moduledoc false
  # The `:importer` seam (#3013), one-shot: the first call runs the test's
  # function (which supersedes the finishing step's lease) instead of
  # importing; every later call imports as usual.
  @key {__MODULE__, :once}

  def arm(fun), do: :persistent_term.put(@key, fun)
  def disarm, do: :persistent_term.erase(@key)

  def run(dir) do
    case :persistent_term.get(@key, nil) do
      nil ->
        KilnCMS.Backups.Importer.run(dir)

      fun ->
        disarm()
        fun.()
    end
  end
end

defmodule KilnCMS.Backups.StepBoundaryTest do
  @moduledoc """
  A backup killed at every step boundary completes on retry without redoing
  the steps it finished (issue 2419's "done when"), and a finish killed after
  it closed the run settles what is left of it.

  Each step is killed two ways:

    * **mid-step**, before its state landed: the node claimed the lock and
      went silent; the step is reclaimed and runs again from the state the
      step before it wrote. Where a dead step leaves partial work (a dump or
      a part half-written, a file sent but not recorded) that work is planted
      and must be redone, never trusted.
    * **after its state landed, before the hand-over**: the next step's job
      already exists, so `Chain.advance/3` fails (`:step_conflict`, the seam
      `chain_test.exs` uses) and the attempt is retried; the retry reuses
      what the state recorded.

  Runs real `pg_dump` and `tar` (`:pg_tools`): every case runs a whole
  backup. Off-site goes to one stored `Fake` destination that logs every file
  it is sent. `async: false`: it changes the VM-wide `Application` env.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import KilnCMS.Test.BackupDestinations, only: [destination!: 1]

  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, Manifest, Recorder, Steps, StepWorker, WorkState}
  alias KilnCMS.Backups.StepBoundaryTest.SupersedingImporter
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bks_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    media = Path.join(base, "media")
    File.mkdir_p!(media)

    # Six 300-byte files with a 700-byte cap: three parts of two files each.
    for n <- 1..6, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original,
        enabled: true,
        dir: dir,
        media_dir: media,
        keep_days: 14,
        media_part_bytes: 700,
        rclone_remote: nil
      )
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    sent_log = Path.join(base, "sent.log")
    destination!(%{position: 1, settings: %{"mode" => "ok", "log" => sent_log}})

    %{dir: dir, sent_log: sent_log}
  end

  ## helpers

  defp request, do: Backups.request([trigger: "manual"], Backups.system())

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  # Run the chain's jobs one at a time until the lock points at `step` (`part`).
  defp step_until(step, part) do
    row = lock()

    if to_string(row.step) == step and row.part == part do
      current_job()
    else
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step, part)
    end
  end

  # The lock's job as if node `node` had claimed it `ago` seconds back.
  defp executing!(job, node, ago) do
    at = DateTime.add(DateTime.utc_now(), -ago, :second)

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [
          state: "executing",
          attempt: job.attempt + 1,
          attempted_at: at,
          attempted_by: [node, Ash.UUID.generate()]
        ]
      )

    Repo.get!(Oban.Job, job.id)
  end

  defp dump_path(dir, stamp), do: Path.join([dir, "db", "kiln-db-#{stamp}.dump"])
  defp part_path(dir, stamp, n), do: Path.join([dir, "media", Artifact.part_name(stamp, n)])
  defp plan_path(dir, stamp), do: Path.join(WorkState.path(dir, stamp), "plan.json")

  # The dump and the media parts that exist now, each aged two hours, with
  # their new mtimes: whatever was finished before the kill.
  defp age_finished(dir, stamp) do
    for path <- [dump_path(dir, stamp) | Enum.map(1..3, &part_path(dir, stamp, &1))],
        File.regular?(path),
        into: %{} do
      File.touch!(path, System.os_time(:second) - 7200)
      {path, mtime(path)}
    end
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  defp sent(sent_log) do
    case File.read(sent_log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp drain_to_end(chain) do
    BackupChain.listen(fn ->
      BackupChain.drain()
      BackupChain.settled(chain)
    end)
  end

  defp run_log(stamp) do
    %{log: log} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
    Enum.map(log, & &1.message)
  end

  # The backup completed as one: one succeeded run of `stamp`, an ok manifest
  # whose artifacts are each listed once, nothing finished before the kill
  # rebuilt, and every file sent off-site once (after `skip` planted lines).
  defp assert_completed(ctx, stamp, kept, skip \\ 0) do
    assert [%{status: :succeeded, stamp: ^stamp} = run] = runs()
    names = Enum.map(run.artifacts, & &1.name)
    assert names == Enum.uniq(names), "the run lists an artifact twice: #{inspect(names)}"
    assert %Manifest{ok: true, stamp: ^stamp, artifacts: artifacts} = Manifest.read(ctx.dir)
    paths = Enum.map(artifacts, & &1.path)
    assert paths == Enum.uniq(paths)
    assert Backups.in_flight() == nil

    for {path, at} <- kept, do: assert(mtime(path) == at, "#{path} was rebuilt")

    files = ctx.sent_log |> sent() |> Enum.drop(skip)
    assert files != []
    assert files == Enum.uniq(files), "a file was sent twice: #{inspect(files)}"
    assert Path.basename(dump_path(ctx.dir, stamp)) in files
    for n <- 1..3, do: assert(Path.basename(part_path(ctx.dir, stamp, n)) in files)
  end

  ## killed mid-step, before its state landed

  # The dead node claimed the lock and went silent; the step is reclaimed.
  defp kill_mid_step(job, next, next_part) do
    {:ok, zombie} = Chain.begin_step(job)
    executing!(job, "dead@node", 600)

    assert {:ok, {:requeued, _}} = Chain.reclaim_stale()

    # The zombie wakes up: it can't move the chain on.
    if next,
      do: assert({:error, :superseded} = Chain.advance(zombie, next, next_part)),
      else: assert({:error, :superseded} = Chain.release(zombie))
  end

  describe "killed mid-step, before its state landed" do
    test "dump: a half-written dump at the final name is rebuilt, never reused", ctx do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("dump", nil)
      %{stamp: stamp} = lock()

      dump = dump_path(ctx.dir, stamp)
      File.mkdir_p!(Path.dirname(dump))
      File.write!(dump, "truncated")

      kill_mid_step(job, "plan", nil)
      assert :ok = drain_to_end(chain)

      assert_completed(ctx, stamp, %{})
      assert File.read!(dump) != "truncated"
      log = run_log(stamp)
      assert Enum.any?(log, &(&1 =~ "Database dump verified"))
      refute Enum.any?(log, &(&1 =~ "Database dump reused"))
    end

    test "plan: planned again, and the chain completes", ctx do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("plan", nil)
      %{stamp: stamp} = lock()
      kept = age_finished(ctx.dir, stamp)

      kill_mid_step(job, "archive", 1)
      assert :ok = drain_to_end(chain)

      assert_completed(ctx, stamp, kept)
    end

    test "archive part 2: a truncated part 2 is rebuilt; the dump and part 1 are not", ctx do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("archive", 2)
      %{stamp: stamp} = lock()
      kept = age_finished(ctx.dir, stamp)

      p2 = part_path(ctx.dir, stamp, 2)
      File.write!(p2, "truncated")

      kill_mid_step(job, "archive", 3)
      assert :ok = drain_to_end(chain)

      assert_completed(ctx, stamp, kept)
      assert {_, 0} = System.cmd("tar", ["-tzf", p2], stderr_to_stdout: true)
    end

    test "offsite: a file the dead node sent but never recorded is sent again", ctx do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("offsite", 1)
      %{stamp: stamp} = lock()
      kept = age_finished(ctx.dir, stamp)

      # The dead node got the dump out before it died; `state["sent"]` doesn't
      # say so.
      File.write!(ctx.sent_log, Path.basename(dump_path(ctx.dir, stamp)) <> "\n")

      kill_mid_step(job, "finish", nil)
      assert :ok = drain_to_end(chain)

      assert_completed(ctx, stamp, kept, 1)
    end

    test "finish: killed after it wrote the manifest, before it closed the run", ctx do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("finish", nil)
      %{stamp: stamp} = lock()
      kept = age_finished(ctx.dir, stamp)

      {:ok, zombie} = Chain.begin_step(job)
      :ok = Chain.mark_finishing(zombie)
      :ok = Manifest.write(ctx.dir, %Manifest{stamp: stamp, trigger: "manual", ok: true})
      executing!(job, "dead@node", 600)

      assert {:ok, {:requeued, _}} = Chain.reclaim_stale()
      assert {:error, :superseded} = Chain.release(zombie)
      assert :ok = drain_to_end(chain)

      assert_completed(ctx, stamp, kept)
      assert File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
    end
  end

  ## killed after its state landed, before the hand-over

  # {step, part, next step, next part}: every hand-over of a backup with a
  # database, three media parts and one destination.
  @handovers [
    {"start", nil, "dump", nil},
    {"dump", nil, "plan", nil},
    {"plan", nil, "archive", 1},
    {"archive", 1, "archive", 2},
    {"archive", 2, "archive", 3},
    {"archive", 3, "checksum", nil},
    {"checksum", nil, "prune", nil},
    {"prune", nil, "offsite", 1},
    {"offsite", 1, "finish", nil}
  ]

  describe "killed after its state landed, before the hand-over" do
    for {step, part, next, next_part} <- @handovers do
      @tag step: step, part: part, next: next, next_part: next_part
      test "#{step}#{if part, do: " part #{part}"} -> #{next}#{if next_part, do: " part #{next_part}"}",
           ctx do
        %{step: step, part: part, next: next, next_part: next_part} = ctx
        {:ok, %{status: :started, chain: chain}} = request()
        step_until(step, part)

        # The next step's job is already there: the hand-over fails after the
        # state write, as if the node died between the two.
        {:ok, blocker} =
          Oban.insert(
            StepWorker.new(%{"chain" => chain, "step" => next, "part" => next_part},
              schedule_in: 3600
            )
          )

        assert %{failure: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
        row = lock()
        assert to_string(row.step) == step and row.part == part

        %{stamp: stamp} = row
        assert {:ok, state} = WorkState.read(WorkState.path(ctx.dir, stamp))
        assert_recorded(step, part, state)

        kept = age_finished(ctx.dir, stamp)
        plan = plan_path(ctx.dir, stamp)
        plan_at = File.regular?(plan) && mtime(plan)

        # The retry alone first (the finish removes the work directory), then
        # the rest of the chain.
        :ok = Oban.cancel_job(blocker.id)
        assert %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: true)
        assert_reused(step, part, stamp, plan_at && {plan, plan_at})

        assert :ok = drain_to_end(chain)
        assert_completed(ctx, stamp, kept)
      end
    end
  end

  # What the step's own state write recorded before the hand-over failed.
  defp assert_recorded("start", _part, state), do: assert(is_binary(WorkState.chain(state)))
  defp assert_recorded("dump", _part, state), do: assert(%{"sha256" => _} = WorkState.dump(state))
  defp assert_recorded("plan", _part, state), do: assert(WorkState.completed?(state, "plan"))

  defp assert_recorded("archive", part, state),
    do: assert(%{"sha256" => _} = WorkState.part(state, part))

  defp assert_recorded("checksum", _part, state),
    do: assert(WorkState.completed?(state, "checksum"))

  defp assert_recorded("prune", _part, _state), do: :ok
  defp assert_recorded("offsite", _part, state), do: assert(map_size(state["sent"]) == 1)

  # The retry reused what the attempt before it finished.
  defp assert_reused("start", _part, _stamp, _plan), do: assert([_one] = runs())

  defp assert_reused("dump", _part, stamp, _plan),
    do: assert(Enum.any?(run_log(stamp), &(&1 =~ "Database dump reused from the original")))

  defp assert_reused("plan", _part, _stamp, {plan, at}), do: assert(mtime(plan) == at)

  defp assert_reused("archive", part, stamp, _plan) do
    {:ok, state} = WorkState.read(Backups.work_dir(stamp))
    assert [[^part, _at]] = state["reused"]
  end

  defp assert_reused(_step, _part, _stamp, _plan), do: :ok

  ## finish interrupted after it closed the run (issue 2419)

  # What `Steps.succeed/4` does before the lock is released, by hand: the
  # steps in `done` (`:manifest` written ok, `:run` closed), then the work
  # directory removed (kept with `:keep_work`). The finish job's node then
  # dies, and `kill` ends it: reclaimed and requeued by default. Setups that
  # `succeed/4` never makes, to pin the rule's guards: `:pending` leaves the
  # destination pending on the Run, `:failed_run` closes the Run failed.
  defp finish_until(ctx, done, kill \\ &requeue!/1) do
    {:ok, %{status: :started, chain: chain}} = request()
    job = step_until("finish", nil)
    %{stamp: stamp} = lock()
    work_dir = WorkState.path(ctx.dir, stamp)
    {:ok, state} = WorkState.read(work_dir)

    {:ok, lease} = Chain.begin_step(job)
    :ok = Chain.mark_finishing(lease)

    rec = Recorder.load(stamp, chain, state["rec"])

    if :pending in done do
      [%{key: key}] = rec.destinations
      rec |> Recorder.put_run_destination(key, %{status: :pending}) |> Recorder.progress()
    end

    if :manifest in done, do: ok_manifest!(ctx.dir, stamp, state)
    if :run in done, do: Recorder.finish(rec)
    if :failed_run in done, do: Recorder.fail(rec, "failed elsewhere")

    unless :keep_work in done, do: File.rm_rf!(work_dir)
    kill.(job)

    {chain, stamp}
  end

  defp requeue!(job) do
    executing!(job, "dead@node", 600)
    assert {:ok, {:requeued, _}} = Chain.reclaim_stale()
  end

  # Reclaimed on its last attempt: the lock is released, nothing is requeued.
  defp last_attempt!(job) do
    job = executing!(job, "dead@node", 600)

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [max_attempts: job.attempt]
      )

    assert {:ok, {:interrupted, _}} = Chain.reclaim_stale()
  end

  # The job ended without finishing its step (its timeout, Lifeline).
  defp reaped!(job) do
    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

    assert {:ok, {:orphaned, _}} = Chain.reap()
  end

  # `finish_until/3` with a kill that settles the chain itself.
  defp finish_killed(ctx, done, kill) do
    {{chain, stamp}, log} =
      ExUnit.CaptureLog.with_log([level: :info], fn ->
        BackupChain.listen(fn -> finish_until(ctx, done, kill) end)
      end)

    {chain, stamp, BackupChain.settled(chain), log}
  end

  defp marked?(dir, stamp) do
    File.exists?(Path.join([dir, "db", Artifact.good_name(stamp)])) and
      File.exists?(Path.join([dir, "media", Artifact.good_name(stamp)]))
  end

  defp ok_manifest!(dir, stamp, state) do
    artifacts =
      for entry <- state["outputs"],
          do: Map.new(entry, fn {k, v} -> {String.to_existing_atom(k), v} end)

    :ok =
      Manifest.write(dir, %Manifest{
        stamp: stamp,
        trigger: "manual",
        ok: true,
        artifacts: artifacts
      })
  end

  defp drain_logged(chain) do
    ExUnit.CaptureLog.with_log([level: :info], fn -> drain_to_end(chain) end)
  end

  describe "finish interrupted after it closed the run" do
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "the retry finds no state, runs the tail: markers, lock, :ok", ctx do
      {chain, stamp} = finish_until(ctx, [:manifest, :run])
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      {outcome, log} = drain_logged(chain)

      assert outcome == :ok
      refute log =~ "Backup FAILED"
      assert log =~ "finished after an interruption"
      assert Backups.in_flight() == nil
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert %Manifest{ok: true, stamp: ^stamp} = Manifest.read(ctx.dir)
      assert File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
      assert File.exists?(Path.join([ctx.dir, "media", Artifact.good_name(stamp)]))
    end

    test "the manifest says ok but the run's close failed: the run is closed, then the tail",
         ctx do
      {chain, stamp} = finish_until(ctx, [:manifest])
      assert %{status: :running} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      {outcome, log} = drain_logged(chain)

      assert outcome == :ok
      refute log =~ "Backup FAILED"
      assert Backups.in_flight() == nil

      assert %{status: :succeeded, log: run_log} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert Enum.any?(run_log, &(&1.message =~ "finished after an interruption"))
      assert %Manifest{ok: true, stamp: ^stamp} = Manifest.read(ctx.dir)
      assert File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
    end

    test "no ok manifest for this stamp and the run still open: lost state, as before", ctx do
      {chain, stamp} = finish_until(ctx, [])

      {outcome, log} = drain_logged(chain)

      assert outcome == {:error, :no_state}
      assert log =~ "Backup FAILED"
      assert Backups.in_flight() == nil

      assert %{status: :failed, error: error} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert error =~ "state.json"
      refute match?(%Manifest{ok: true}, Manifest.read(ctx.dir))
      refute File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
    end

    test "an ok manifest for an older stamp doesn't count: lost state", ctx do
      assert :ok = BackupChain.run()
      assert [%{stamp: older}] = runs()

      {chain, stamp} = finish_until(ctx, [])
      assert %Manifest{ok: true, stamp: ^older} = Manifest.read(ctx.dir)

      {outcome, log} = drain_logged(chain)

      assert outcome == {:error, :no_state}
      assert log =~ "Backup FAILED"
      assert %{status: :failed} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      refute marked?(ctx.dir, stamp)
    end

    test "an ok manifest for this stamp but a run closed failed: lost state", ctx do
      {chain, stamp} = finish_until(ctx, [:manifest, :failed_run])

      {outcome, log} = drain_logged(chain)

      assert outcome == {:error, :no_state}
      assert log =~ "Backup FAILED"
      refute log =~ "finished after an interruption"
      assert %{status: :failed} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      refute marked?(ctx.dir, stamp)
    end

    test "a destination still pending on the run is settled failed when it is closed", ctx do
      {chain, stamp} = finish_until(ctx, [:pending, :manifest])

      assert {:ok, _log} = drain_logged(chain)

      assert %{status: :succeeded, offsite_status: :failed, destinations: [destination]} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert %{status: :failed, error: error} = destination
      assert error =~ "not attempted"
    end

    test "the run can't be read: the finish is retried, and nothing is written", ctx do
      {chain, stamp} = finish_until(ctx, [:manifest, :run])
      job = current_job()
      {:ok, lease} = Chain.begin_step(job)

      assert {:error, {:run_read, _}} =
               Backups.with_actor(nil, fn -> Steps.perform(lease, job) end)

      assert %{chain: ^chain} = Backups.in_flight()
      refute marked?(ctx.dir, stamp)
    end
  end

  describe "finish interrupted after it closed the run, then ended from outside" do
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "reclaimed on its last attempt: completed, not failed", ctx do
      {_chain, stamp, outcome, log} = finish_killed(ctx, [:manifest, :run], &last_attempt!/1)

      assert outcome == :ok
      refute log =~ "the backup failed"
      assert log =~ "finished after an interruption"
      assert Backups.in_flight() == nil
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert marked?(ctx.dir, stamp)
    end

    test "reaped: completed, not failed", ctx do
      {_chain, stamp, outcome, log} = finish_killed(ctx, [:manifest, :run], &reaped!/1)

      assert outcome == :ok
      refute log =~ "the backup failed"
      assert Backups.in_flight() == nil
      assert %{status: :succeeded} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert marked?(ctx.dir, stamp)
    end

    test "reaped with the run still open and the work directory still there", ctx do
      {_chain, stamp, outcome, _log} =
        finish_killed(ctx, [:manifest, :keep_work], &reaped!/1)

      assert outcome == :ok

      assert %{status: :succeeded, log: run_log} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert Enum.any?(run_log, &(&1.message =~ "finished after an interruption"))
      refute File.exists?(WorkState.path(ctx.dir, stamp))
      assert marked?(ctx.dir, stamp)
    end

    test "reaped with no ok manifest for this stamp: failed, as before", ctx do
      {_chain, stamp, outcome, log} = finish_killed(ctx, [], &reaped!/1)

      assert outcome == {:error, :unsettled}
      assert log =~ "the backup failed"
      assert %{status: :failed} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      refute marked?(ctx.dir, stamp)
    end

    test "a run that can't be read is recorded as interrupted, never completed", ctx do
      {chain, stamp} = finish_until(ctx, [:manifest, :run])

      BackupChain.listen(fn ->
        assert :ok =
                 Backups.with_actor(nil, fn ->
                   Steps.interrupt_finish(stamp, chain, nil, "Interrupted: test")
                 end)
      end)

      assert BackupChain.settled(chain) == {:error, :unsettled}
      refute marked?(ctx.dir, stamp)
    end
  end

  ## #3012 and #3013: the finish and the lock

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "boundary-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp canceled_events(actor) do
    Security.list_instance_events!(actor: actor, page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :backup_canceled))
  end

  # Every `.good` and `.hold` marker in the backup directory, with its bytes.
  defp markers(dir) do
    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(dir, sub)),
        Path.extname(name) in [".good", ".hold"],
        into: %{} do
      path = Path.join([dir, sub, name])
      {path, File.read!(path)}
    end
  end

  describe "#3012: a reclaimed finishing step" do
    test "stays finishing, so a Cancel in the gap is refused; the replacement completes", ctx do
      {chain, stamp} = finish_until(ctx, [:keep_work])
      admin = admin()

      # Requeued: the replacement job hasn't run `mark_finishing/1` yet.
      row = lock()
      assert %{chain_id: ^chain, phase: :finishing, step: :finish} = row
      run = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert run.status == :running

      assert {:error, %Ash.Error.Invalid{} = error} = Backups.cancel_run(run, actor: admin)
      assert Exception.message(error) =~ "too late to cancel"

      assert %{status: :running} = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert lock() == row
      assert canceled_events(admin) == []

      assert :ok = drain_to_end(chain)
      assert_completed(ctx, stamp, %{})
    end
  end

  describe "#3013: a finish whose lease is superseded before its marker sync" do
    setup do
      on_exit(&SupersedingImporter.disarm/0)
    end

    test "writes no marker and releases nothing; the step that took over syncs them", ctx do
      # An older backup, marked good, and a hold marker no schedule names: a
      # sync would move the first and remove the second.
      # Planted once the chain reaches its finish: its prune step syncs the
      # markers too.
      assert :ok = BackupChain.run()
      assert [%{stamp: older}] = runs()

      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("finish", nil)
      %{stamp: stamp} = lock()

      File.write!(Path.join([ctx.dir, "db", Artifact.hold_name(older)]), "")
      before = markers(ctx.dir)
      assert Map.has_key?(before, Path.join([ctx.dir, "db", Artifact.good_name(older)]))

      # The finish stalls in its import past the reclaim window: its node is
      # judged stopped and the step requeued, under a new lease.
      SupersedingImporter.arm(fn ->
        executing!(job, "dead@node", 600)
        {:ok, {:requeued, _}} = Chain.reclaim_stale()
        {:ok, %{}}
      end)

      config = Application.get_env(:kiln_cms, KilnCMS.Backups)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(config, :importer, SupersedingImporter)
      )

      assert {:cancel, :superseded} = StepWorker.perform(job)

      assert markers(ctx.dir) == before
      refute File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
      assert %{chain: ^chain, step: :finish} = Backups.in_flight()

      assert :ok = drain_to_end(chain)
      assert File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(stamp)]))
      refute File.exists?(Path.join([ctx.dir, "db", Artifact.good_name(older)]))
      assert Backups.in_flight() == nil
    end
  end
end
