defmodule KilnCMS.Backups.StepWorkerTest do
  @moduledoc """
  Which node runs a backup step (#2218, D1): every step after `start` runs
  where the chain's files are, told by `<BACKUP_DIR>/.kiln-dir-id`. `async:
  false`: it points the VM-wide backup directory at a temporary one.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{DirId, StepWorker, WorkState}

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_bks_#{System.unique_integer([:positive])}")
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(dir)
    end)

    {:ok, local} = DirId.local()
    %{dir: dir, local: local}
  end

  defp args(dir_id) do
    %{
      "chain" => Ash.UUID.generate(),
      "step" => "dump",
      "part" => nil,
      "stamp" => "20260101-000000",
      "dir" => dir_id
    }
  end

  # #2223: an upload a step's time limit cuts off stays open for the next
  # attempt, which Oban's Lifeline only starts once the step's own limit has
  # passed. A step's adapter calls end 5 minutes before that limit
  # (`Steps.call_deadline/1`).
  test "a step's time limit sits inside the Lifeline rescue window" do
    rescue_after = KilnCMS.Application.oban_rescue_after() || :timer.minutes(180)
    assert StepWorker.timeout(%Oban.Job{}) < rescue_after
  end

  test "the directory id is created once, private, and read back", %{dir: dir, local: local} do
    assert {:ok, ^local} = DirId.local()
    assert {:ok, ^local} = DirId.current()
    assert %{mode: mode} = File.stat!(DirId.path(dir))
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "a step for another backup directory snoozes without spending an attempt" do
    {:ok, job} = Oban.insert(StepWorker.new(args(Ash.UUID.generate())))

    assert %{snoozed: 1} =
             Oban.drain_queue(queue: :backup_steps, with_scheduled: false)

    assert %{state: "scheduled", attempt: 0, meta: %{"snoozed" => 1}} =
             KilnCMS.Repo.get!(Oban.Job, job.id)
  end

  test "after twenty snoozes it fails the attempt, so the backoff and budget take over" do
    assert {:snooze, 30} = perform_job(StepWorker, args(Ash.UUID.generate()))

    assert {:error, :backup_dir_elsewhere} =
             perform_job(StepWorker, args(Ash.UUID.generate()), meta: %{"snoozed" => 20})
  end

  test "the snooze budget is per attempt: the next attempt on the wrong node snoozes again" do
    {:ok, job} = Oban.insert(StepWorker.new(args(Ash.UUID.generate()), meta: %{"snoozed" => 20}))

    # Attempt 1 has used its twenty snoozes: it fails.
    assert %{failure: 1} = Oban.drain_queue(queue: :backup_steps, with_scheduled: false)
    assert %{state: "retryable", attempt: 1} = KilnCMS.Repo.get!(Oban.Job, job.id)

    # Attempt 2, still on the wrong node, starts a budget of its own.
    assert %{snoozed: 1} = Oban.drain_queue(queue: :backup_steps, with_scheduled: true)

    assert %{state: "scheduled", attempt: 1, meta: %{"snoozed" => 21}} =
             KilnCMS.Repo.get!(Oban.Job, job.id)
  end

  test "snoozes before an attempt got past the check don't count against the next one", %{
    local: local
  } do
    # Ten snoozes, then a node with the right directory picked it up.
    {:ok, job} = Oban.insert(StepWorker.new(args(local), meta: %{"snoozed" => 10}))
    assert %{cancelled: 1} = Oban.drain_queue(queue: :backup_steps, with_scheduled: false)

    assert %{meta: %{"snoozed" => 10, "affinity_base" => 10}} =
             KilnCMS.Repo.get!(Oban.Job, job.id)
  end

  test "a node with no directory id is not the chain's node", %{dir: dir} do
    File.rm!(DirId.path(dir))
    assert {:snooze, 30} = perform_job(StepWorker, args(Ash.UUID.generate()))
  end

  test "a step is unregistered once it returns, so the heartbeat never sees it done (#2538)", %{
    local: local
  } do
    %{"chain" => chain} = job_args = args(local)
    {:ok, _job} = Oban.insert(StepWorker.new(job_args))

    assert %{cancelled: 1} = Oban.drain_queue(queue: :backup_steps, with_scheduled: false)
    assert Registry.lookup(KilnCMS.Backups.StepRegistry, chain) == []
  end

  test "a shared directory id runs anywhere: the step goes on to claim the lock", %{
    local: local
  } do
    # Past the affinity check; this job is not the lock's, so it is superseded.
    assert {:cancel, :superseded} = perform_job(StepWorker, args(local))
  end

  describe "a resume's start (#2539)" do
    # A failed run whose files are in the directory `dir_id` names.
    defp run!(dir_id) do
      # A real time of day, unique per call: `WorkState.path/2` checks it.
      at = Time.add(~T[00:00:00], rem(System.unique_integer([:positive]), 86_400))
      stamp = "20260101-" <> String.replace(Time.to_iso8601(at), ":", "")

      Ash.Seed.seed!(KilnCMS.Backups.Run, %{
        stamp: stamp,
        status: :failed,
        error: "tar exited 2",
        dir_id: dir_id
      })
    end

    defp start_args(stamp) do
      %{"chain" => Ash.UUID.generate(), "step" => "start", "part" => nil, "resume" => stamp}
    end

    defp state!(dir, stamp) do
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
      work
    end

    test "with its files in another node's directory, it snoozes" do
      run = run!(Ash.UUID.generate())
      assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "with its files here it runs when no live node reports the recorded id", %{dir: dir} do
      run = run!(Ash.UUID.generate())
      state!(dir, run.stamp)
      # Past the affinity check; not the lock's job, so superseded.
      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "on the node whose directory the run records it runs, files or not", %{local: local} do
      run = run!(local)
      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a run with no directory id runs anywhere" do
      run = run!(nil)
      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a fresh backup's start runs anywhere" do
      args = %{"chain" => Ash.UUID.generate(), "step" => "start", "part" => nil}
      assert {:cancel, :superseded} = perform_job(StepWorker, args)
    end

    # Critic amendment 2: the same budget as every other step.
    test "an attempt that spent its snoozes fails, and the next attempt waits again" do
      run = run!(Ash.UUID.generate())

      assert {:error, :backup_dir_elsewhere} =
               perform_job(StepWorker, start_args(run.stamp),
                 meta: %{"snoozed" => 20},
                 attempt: 3,
                 max_attempts: 4
               )
    end

    test "the last attempt with its snoozes spent gives the resume up: lock freed, run noted",
         %{dir: dir} do
      other = Ash.UUID.generate()
      run = run!(other)
      state!(dir, run.stamp)

      assert {:ok, %{status: :started, chain: chain}} =
               Backups.request([resume: run.stamp], Backups.system())

      File.rm_rf!(WorkState.path(dir, run.stamp))

      job =
        KilnCMS.Repo.one!(from(j in Oban.Job, where: fragment("?->>'chain' = ?", j.args, ^chain)))

      assert {:cancel, {:backup_dir_elsewhere, ^other}} =
               StepWorker.perform(%{job | attempt: 4, max_attempts: 4, meta: %{"snoozed" => 20}})

      assert Backups.in_flight() == nil

      noted = Backups.get_run!(run.id, actor: Backups.system())
      assert noted.status == :failed
      assert noted.error =~ ~r/\AResume refused: no server with its backup directory/
      assert noted.error =~ ~r/\ntar exited 2\z/
    end

    test "giving up a start the lock no longer names writes nothing" do
      run = run!(Ash.UUID.generate())

      job = %Oban.Job{
        id: 1,
        attempt: 4,
        max_attempts: 4,
        args: start_args(run.stamp),
        meta: %{"snoozed" => 20}
      }

      assert {:cancel, :superseded} = StepWorker.perform(job)
      assert %{error: "tar exited 2"} = Backups.get_run!(run.id, actor: Backups.system())
    end
  end

  describe "a resume's start with a copy of the files here (#2817)" do
    alias KilnCMS.Test.BackupCluster

    # The source host: a live node whose beat reports `dir_id`.
    defp source_beat!(dir_id) do
      Backups.beat_node!(%{node: "a@host", boot_id: Ash.UUID.generate(), dir_id: dir_id},
        actor: Backups.system()
      )

      "a@host"
    end

    defp put_beats_reader(reader) do
      env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(env, :live_beats_reader, reader)
      )
    end

    test "an orphan copy waits while the source host's beat reports the run's id", %{dir: dir} do
      source = Ash.UUID.generate()
      source_beat!(source)
      run = run!(source)
      state!(dir, run.stamp)

      assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a source whose id read is held up still counts: the copy waits", %{dir: dir} do
      # The source's beat carries no id (its read is stuck, #2848) but the
      # last id it read.
      source = Ash.UUID.generate()

      Backups.beat_node!(
        %{node: "a@host", boot_id: Ash.UUID.generate(), dir_id: nil, last_dir_id: source},
        actor: Backups.system()
      )

      run = run!(source)
      state!(dir, run.stamp)

      assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a source beat 181 s old is not live: the copy resumes here", %{dir: dir} do
      source = Ash.UUID.generate()
      BackupCluster.backdate_beat!(source_beat!(source), 181)
      run = run!(source)
      state!(dir, run.stamp)

      # Past the affinity check; not the lock's job, so superseded.
      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a source beat 179 s old is live: the copy waits", %{dir: dir} do
      source = Ash.UUID.generate()
      BackupCluster.backdate_beat!(source_beat!(source), 179)
      run = run!(source)
      state!(dir, run.stamp)

      assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
    end

    test "a state.json that can't be parsed is no copy: the start waits", %{dir: dir} do
      for content <- ["{}", "not json"] do
        run = run!(Ash.UUID.generate())
        work = state!(dir, run.stamp)
        File.write!(WorkState.file(work), content)

        # The file is there (the Resume button and the request still see it),
        # but it is nothing to resume from.
        assert Backups.work_state?(run.stamp)
        refute Backups.local_resume_state?(run.stamp)
        assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
      end
    end

    test "heartbeats that can't be read count as a live source: the copy waits, and says so",
         %{dir: dir} do
      put_beats_reader(fn _within_s -> {:error, :connection_refused} end)
      source = Ash.UUID.generate()
      run = run!(source)
      state!(dir, run.stamp)

      log =
        capture_log([level: :warning], fn ->
          assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
        end)

      assert log =~
               "Backup resume of #{run.stamp}: couldn't read the node heartbeats " <>
                 "(:connection_refused); waiting for the server with its backup directory " <>
                 "(id #{source}) rather than resuming from the files here"
    end

    # The run's row can't be read (here: its table is off the search path, so
    # the read fails in the database, as on a blip). A copy must not win then.
    defp break_run_reads!, do: KilnCMS.Repo.query!("SET LOCAL search_path TO pg_catalog")

    test "a run that can't be read: with a copy here the start waits, and says so", %{dir: dir} do
      run = run!(Ash.UUID.generate())
      state!(dir, run.stamp)
      break_run_reads!()

      log =
        capture_log([level: :warning], fn ->
          assert {:snooze, 30} = perform_job(StepWorker, start_args(run.stamp))
        end)

      assert log =~ "Backup resume of #{run.stamp}: couldn't read where its files are ("
      assert log =~ "); waiting rather than resuming from the files here"
    end

    test "a run that can't be read: a spent budget fails the attempt, and the last one too",
         %{dir: dir} do
      run = run!(Ash.UUID.generate())
      state!(dir, run.stamp)
      break_run_reads!()

      # No id: nothing to write the snooze base to on the broken connection.
      job = %Oban.Job{args: start_args(run.stamp), meta: %{"snoozed" => 20}, max_attempts: 4}

      assert {:error, :run_unreadable} = StepWorker.perform(%{job | attempt: 3})
      assert {:error, :run_unreadable} = StepWorker.perform(%{job | attempt: 4})
    end

    test "a run that can't be read: with no files here the start runs and refuses on them" do
      run = run!(Ash.UUID.generate())
      break_run_reads!()

      log =
        capture_log([level: :warning], fn ->
          # Past the affinity check (the lock check then fails on the same
          # broken read).
          refute match?({:snooze, _}, perform_job(StepWorker, start_args(run.stamp)))
        end)

      assert log =~ "); starting it here"
    end

    test "the heartbeats are read only when there are files here to win with", %{local: local} do
      test = self()

      # Directory queues off: routing a job to one (#2845) reads the beats too,
      # for another reason than this check.
      env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(env, :dir_queues?, false))

      put_beats_reader(fn within_s ->
        send(test, {:beats_read, within_s})
        {:ok, []}
      end)

      # No files here: pinned without a read.
      assert {:snooze, 30} = perform_job(StepWorker, start_args(run!(Ash.UUID.generate()).stamp))
      # The run's own directory: runs without a read.
      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run!(local).stamp))
      refute_received {:beats_read, _}
    end

    test "the read asks for the lock's stale threshold", %{dir: dir} do
      test = self()

      put_beats_reader(fn within_s ->
        send(test, {:beats_read, within_s})
        {:ok, []}
      end)

      run = run!(Ash.UUID.generate())
      state!(dir, run.stamp)

      assert {:cancel, :superseded} = perform_job(StepWorker, start_args(run.stamp))
      assert_received {:beats_read, 180}
      assert KilnCMS.Backups.Chain.stale_after_s() == 180
    end
  end
end
