defmodule KilnCMS.Backups.StepWorkerTest do
  @moduledoc """
  Which node runs a backup step (#2218, D1): every step after `start` runs
  where the chain's files are, told by `<BACKUP_DIR>/.kiln-dir-id`. `async:
  false`: it points the VM-wide backup directory at a temporary one.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query

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

    test "with its files here it runs, whatever id the run records", %{dir: dir} do
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
end
