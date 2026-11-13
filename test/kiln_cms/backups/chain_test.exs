defmodule KilnCMS.Backups.ChainTest do
  @moduledoc """
  The backup step chain and its lock (#2218): requests that start, queue and
  fold; the steps' fencing; a step whose node stopped; a step whose job ended
  without finishing it; the failures a retry can't fix.

  Runs real `pg_dump` and `tar` (`:pg_tools`), stepping the chain one job at a
  time where a test needs to act between steps. `async: false`: it changes the
  VM-wide `Application` env and PATH.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, DirId, Manifest, StepWorker, Worker, WorkState}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkc_#{System.unique_integer([:positive])}")
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
        media_part_bytes: 700
      )
    )

    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, media: media}
  end

  defp request(opts \\ []), do: Backups.request(opts, Backups.system())

  defp runs, do: Backups.list_runs!(actor: Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp step_jobs(chain) do
    Repo.all(
      from(j in Oban.Job,
        where: j.queue == "backup_steps" and fragment("?->>'chain' = ?", j.args, ^chain),
        order_by: j.id
      )
    )
  end

  # The one job the lock points at.
  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  # Run the chain's jobs one at a time until the lock points at `step` (`part`).
  defp step_until(step, part \\ nil) do
    row = lock()

    if to_string(row.step) == step and row.part == part do
      current_job()
    else
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step, part)
    end
  end

  defp aged(path) do
    File.touch!(path, System.os_time(:second) - 7200)
    File.stat!(path, time: :posix).mtime
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  # Same size, one byte different.
  defp flip_byte!(path) do
    data = File.read!(path)
    mid = div(byte_size(data), 2)
    <<head::binary-size(^mid), byte, tail::binary>> = data
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)
  end

  defp set_config(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups), overrides)
    )
  end

  describe "the worker's shape" do
    test "steps run on their own queue, four attempts, 1/5/15 minutes apart" do
      opts = StepWorker.__opts__()
      assert opts[:queue] == :backup_steps
      assert opts[:max_attempts] == 4

      assert Enum.map(1..3, &StepWorker.backoff(%Oban.Job{attempt: &1, max_attempts: 4})) ==
               [60, 300, 900]

      # A reclaimed step's replacement (two attempts left, after the first two
      # were used) carries on with the schedule rather than starting over.
      assert StepWorker.backoff(%Oban.Job{attempt: 1, max_attempts: 2}) == 900

      assert StepWorker.timeout(%Oban.Job{}) == :timer.hours(2)
    end

    test "both queues are configured: the legacy one drains, the new one runs the chain" do
      queues = Application.fetch_env!(:kiln_cms, Oban)[:queues]
      assert queues[:backup_steps] == 1
      assert queues[:backups] == 1
    end

    test "unique per chain, step and part: two chains both insert, one chain once" do
      a = Ash.UUID.generate()
      b = Ash.UUID.generate()
      args = fn chain -> %{"chain" => chain, "step" => "archive", "part" => 2} end

      assert {:ok, %{conflict?: false}} = Oban.insert(StepWorker.new(args.(a)))
      assert {:ok, %{conflict?: false}} = Oban.insert(StepWorker.new(args.(b)))
      assert {:ok, %{conflict?: true}} = Oban.insert(StepWorker.new(args.(a)))

      assert {:ok, %{conflict?: false}} =
               Oban.insert(StepWorker.new(%{args.(a) | "part" => 3}))
    end
  end

  describe "requests (D2)" do
    test "a request on a free lock starts a chain; the second is queued behind it" do
      assert {:ok, %{status: :started, chain: chain}} = request(trigger: "manual")
      assert %{chain: ^chain, step: :start, waiting: nil} = Backups.in_flight()

      assert {:ok, %{status: :queued, chain: ^chain}} = request(trigger: "schedule")

      assert %{waiting: %{trigger: "schedule", folds: 0, requested_at: %DateTime{}}} =
               Backups.in_flight()

      assert [%Oban.Job{args: %{"step" => "start"}}] = step_jobs(chain)
    end

    test "an over-long trigger is cut to the Run's 64 characters, never refused" do
      long = String.duplicate("t", 300)

      assert {:ok, %{status: :started}} = request(trigger: long)
      assert {:ok, %{status: :queued}} = request(trigger: long)

      cut = String.duplicate("t", 64)
      assert %{trigger: ^cut, waiting: %{trigger: ^cut}} = Backups.in_flight()
    end

    test "the third and fourth fold into the queued one, counted and logged" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:kiln_cms, :backups, :request, :folded]])

      # An info line, below the test config's level (this module is not async).
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      {result, log} =
        ExUnit.CaptureLog.with_log([level: :info], fn ->
          {request(trigger: "schedule"), request(trigger: "manual")}
        end)

      assert {{:ok, %{status: :folded}}, {:ok, %{status: :folded}}} = result
      assert log =~ "Backup request folded"
      assert_received {[:kiln_cms, :backups, :request, :folded], ^ref, %{count: 1}, _}
      assert_received {[:kiln_cms, :backups, :request, :folded], ^ref, %{count: 1}, _}
      assert %{waiting: %{trigger: "schedule", folds: 2}} = Backups.in_flight()
    end

    test "a request that can't run here is refused before it touches the lock" do
      set_config(enabled: false)
      assert {:error, :disabled} = request()
      assert Backups.in_flight() == nil
    end

    test "a resume of the stamp the running chain holds is refused as in flight" do
      {:ok, %{status: :started}} = request()
      BackupChain.drain(with_recursion: false)
      %{stamp: stamp} = Backups.in_flight()
      assert is_binary(stamp)

      assert {:error, :in_flight} = request(resume: stamp)
      assert {:error, :in_flight} = Backups.resumable_run(stamp)
    end

    test "a queued request doesn't sweep; the start step does, once it holds the lock", %{
      dir: dir
    } do
      partial = Path.join([dir, "db", "kiln-db-20200101-000000.dump.partial"])
      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "abandoned")
      File.touch!(partial, System.os_time(:second) - 7200)

      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request()
      assert File.exists?(partial)

      BackupChain.drain(with_recursion: false)
      refute File.exists?(partial)
    end

    test "release promotes the queued request: a new chain, its own stamp, the folds on its log" do
      {:ok, %{status: :started, chain: first}} = request(trigger: "manual")
      {:ok, %{status: :queued}} = request(trigger: "schedule")
      {:ok, %{status: :folded}} = request(trigger: "schedule")
      {:ok, %{status: :folded}} = request(trigger: "manual")

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(first)
        assert_received {:chain_settled, second, :ok} when second != first
      end)

      assert [a, b] = Enum.sort_by(runs(), & &1.stamp)
      assert a.status == :succeeded and b.status == :succeeded
      assert a.stamp != b.stamp and a.chain_id != b.chain_id
      assert a.chain_id == first
      assert b.trigger == "schedule"

      assert Enum.any?(
               b.log,
               &(&1.message =~ ~r/\AStarted from the queue \(requested at .+\); 2 later request/)
             )

      assert Backups.in_flight() == nil
    end
  end

  describe "like folds only into like (#2540)" do
    # A failed in-app run that kept its state: one `request(resume: stamp)` takes.
    defp resumable!(dir, stamp) do
      run =
        Backups.start_run!(%{stamp: stamp, trigger: "manual", components: [:db, :media]},
          actor: Backups.system()
        )

      Backups.fail_run!(run, %{error: "tar exited 2"}, actor: Backups.system())
      work = WorkState.path(dir, stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(stamp))
      stamp
    end

    # What a refused request must leave alone: the lock row's queue, the Runs
    # and the step jobs.
    defp snapshot do
      row = lock()

      {Map.take(row, [
         :chain_id,
         :step_job_id,
         :waiting_trigger,
         :waiting_resume_stamp,
         :waiting_requested_at,
         :waiting_requested_by,
         :waiting_folds,
         :last_folded_at
       ]), Enum.map(runs(), & &1.id) |> Enum.sort(), Repo.aggregate(Oban.Job, :count)}
    end

    test "a fresh backup folds into a queued fresh backup" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      assert {:ok, %{status: :folded}} = request(trigger: "manual")
      assert %{waiting: %{resume: nil, folds: 1}} = Backups.in_flight()
    end

    test "a resume folds into a queued resume of the same stamp", %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)

      assert {:ok, %{status: :folded}} = request(resume: stamp)
      assert %{waiting: %{resume: ^stamp, folds: 1}} = Backups.in_flight()
    end

    test "a fresh backup is refused while a resume is queued; nothing changes", %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)
      before = snapshot()

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:kiln_cms, :backups, :request, :folded]])

      assert {:error, {:queue_busy, {:resume, ^stamp}}} = request(trigger: "manual")
      assert {:error, {:queue_busy, {:resume, ^stamp}}} = request(trigger: "schedule")

      assert snapshot() == before
      assert %{waiting: %{resume: ^stamp, folds: 0}} = Backups.in_flight()
      refute_received {[:kiln_cms, :backups, :request, :folded], ^ref, _, _}
    end

    test "a resume is refused while a fresh backup is queued; nothing changes", %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(trigger: "schedule")
      before = snapshot()

      assert {:error, {:queue_busy, :backup}} = request(resume: stamp)

      assert snapshot() == before
      assert %{waiting: %{resume: nil, trigger: "schedule", folds: 0}} = Backups.in_flight()
    end

    test "a resume is refused while a resume of another stamp is queued", %{dir: dir} do
      queued = resumable!(dir, "20261101-101010")
      other = resumable!(dir, "20261102-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: queued)
      before = snapshot()

      assert {:error, {:queue_busy, {:resume, ^queued}}} = request(resume: other)
      assert snapshot() == before
    end

    # #2671's whole repro: the refused resume is not lost to a fold. When the
    # running backup ends, the queued resume is the one that runs, and the
    # refused one can then be asked for again.
    test "a resume behind a queued resume of another run is refused, then accepted (#2671)",
         %{dir: dir} do
      b = resumable!(dir, "20261101-101010")
      c = resumable!(dir, "20261102-101010")
      {:ok, %{status: :started, chain: a}} = request()
      {:ok, %{status: :queued, chain: ^a}} = request(resume: b)
      before = snapshot()

      assert {:error, {:queue_busy, {:resume, ^b}}} = request(resume: c)
      assert snapshot() == before
      assert %{chain: ^a, waiting: %{resume: ^b, folds: 0}} = Backups.in_flight()

      # Run A ends: B's resume is promoted, and nothing waits behind it.
      assert {:ok, promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      assert promoted != a
      assert %{chain: ^promoted, stamp: ^b, waiting: nil} = Backups.in_flight()

      # C's resume is now accepted, queued behind B's.
      assert {:ok, %{status: :queued, chain: ^promoted}} = request(resume: c)

      assert %{chain: ^promoted, stamp: ^b, waiting: %{resume: ^c, folds: 0}} =
               Backups.in_flight()
    end

    test "once the queue clears, the refused request is accepted", %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)
      {:error, {:queue_busy, _}} = request()

      # The running chain ends: the queued resume is promoted, and the queue
      # is free again, so the fresh backup now queues behind the resume.
      assert {:ok, promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      assert %{chain: ^promoted, stamp: ^stamp, waiting: nil} = Backups.in_flight()

      assert {:ok, %{status: :queued, chain: ^promoted}} = request()
      assert %{waiting: %{resume: nil}} = Backups.in_flight()
    end

    test "a legacy Worker job waits and asks again while a resume is queued", %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)

      assert {:snooze, 60} = Worker.perform(%Oban.Job{id: 7, args: %{"trigger" => "manual"}})
      assert %{waiting: %{resume: ^stamp, folds: 0}} = Backups.in_flight()
    end

    test "a legacy resume job waits while a fresh backup is queued; Worker.run/3 says why",
         %{dir: dir} do
      stamp = resumable!(dir, "20261101-101010")
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      assert {:snooze, 60} =
               Worker.perform(%Oban.Job{id: 7, args: %{"trigger" => "manual", "resume" => stamp}})

      assert {:error, {:queue_busy, :backup}} = Worker.run("console", nil, resume: stamp)
      assert %{waiting: %{resume: nil, folds: 0}} = Backups.in_flight()
    end
  end

  # Part of #2219: a scheduled request's window claims run inside the lock
  # transaction, after the decision.
  describe "the claim" do
    test "a claim that errors rolls back the decision's lock write and its Oban insert" do
      jobs = Repo.aggregate(Oban.Job, :count)
      parent = self()

      claim = fn status ->
        send(parent, {:claimed, status})
        {:error, :window_taken}
      end

      assert {:error, :window_taken} =
               Chain.request(%{trigger: "schedule", components: [:db], claim: claim})

      assert_received {:claimed, :started}
      assert Repo.aggregate(Oban.Job, :count) == jobs
      assert %{chain_id: nil, step_job_id: nil, epoch: 0} = lock()
    end

    test "a refused decision never runs the claim" do
      {:ok, %{status: :started}} = request()
      claim = fn _status -> flunk("the claim must not run") end

      set_config(enabled: false)
      assert {:error, :disabled} = Chain.request(%{trigger: "schedule", claim: claim})
    end

    test "with no :claim, request/1 behaves as before" do
      assert {:ok, %{status: :started}} = Chain.request(%{trigger: "manual"})
      assert {:ok, %{status: :queued}} = Chain.request(%{trigger: "manual"})
      assert {:ok, %{status: :folded}} = Chain.request(%{trigger: "manual"})
    end
  end

  describe "fencing" do
    test "a step of another chain, or an old job of this one, does not begin" do
      {:ok, %{status: :started, chain: chain}} = request()
      job = current_job()

      other = %{job | args: Map.put(job.args, "chain", Ash.UUID.generate())}
      assert {:error, :superseded} = Chain.begin_step(other)
      assert {:error, :superseded} = Chain.begin_step(%{job | id: job.id + 1_000_000})

      assert {:ok, %{chain: ^chain, stamp: stamp}} = Chain.begin_step(job)
      assert is_binary(stamp)
    end

    test "a retried start keeps the stamp it settled on, and its Run" do
      {:ok, %{status: :started, chain: chain}} = request()
      job = current_job()

      assert {:ok, %{stamp: stamp, dir_id: dir_id}} = Chain.begin_step(job)
      # The same job again, as a retry: same stamp, same backup directory.
      assert {:ok, %{stamp: ^stamp, dir_id: ^dir_id}} = Chain.begin_step(job)

      rec = Backups.Recorder.open(stamp, "manual", DateTime.utc_now(), [:db], job.id, chain)
      again = Backups.Recorder.open(stamp, "manual", DateTime.utc_now(), [:db], job.id, chain)
      assert rec.run.id == again.run.id
      assert [%{chain_id: ^chain}] = runs()
    end

    test "an advance whose lease is stale inserts nothing" do
      {:ok, %{status: :started, chain: chain}} = request()
      {:ok, lease} = Chain.begin_step(current_job())

      assert {:error, :superseded} = Chain.advance(%{lease | epoch: lease.epoch - 1}, "dump")
      assert [_start] = step_jobs(chain)
    end

    test "while_holding runs its function only for the lease that holds the lock (D4)" do
      {:ok, %{status: :started}} = request()
      {:ok, lease} = Chain.begin_step(current_job())

      assert {:ok, :ran} = Chain.while_holding(lease, fn -> :ran end)

      # A cancel or reclaim moved the lock on: a failing step's manifest write
      # must not happen.
      stale = %{lease | epoch: lease.epoch - 1}
      assert {:error, :superseded} = Chain.while_holding(stale, fn -> flunk("ran") end)
    end

    test "an advance whose next job already exists rolls back and leaves the lock alone" do
      {:ok, %{status: :started, chain: chain}} = request()
      {:ok, lease} = Chain.begin_step(current_job())
      before = lock()

      {:ok, _} = Oban.insert(StepWorker.new(%{"chain" => chain, "step" => "dump", "part" => nil}))

      assert {:error, :step_conflict} = Chain.advance(lease, "dump")
      after_ = lock()
      assert after_.epoch == before.epoch
      assert after_.step == :start
      assert after_.step_job_id == before.step_job_id
    end
  end

  describe "the backup directory" do
    test "a start that failed before its state landed binds the directory its retry wrote to, " <>
           "on another node; later steps follow it there",
         %{base: base, dir: dir} do
      {:ok, %{status: :started, chain: chain}} = request()

      # Node A: its backup directory can't hold a work directory.
      {:ok, a} = DirId.local(dir)
      File.write!(Path.join(dir, ".work"), "")
      assert %{failure: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      assert %{step: :start, dir_id: nil} = lock()

      # The retry runs on node B, with a BACKUP_DIR of its own.
      other = Path.join(base, "backups-b")
      set_config(dir: other)
      {:ok, b} = DirId.local(other)
      assert b != a

      assert %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: true)
      row = lock()
      assert row.step == :dump and row.dir_id == b
      assert %{args: %{"dir" => ^b}} = current_job()
      assert WorkState.exists?(WorkState.path(other, row.stamp))
      refute WorkState.exists?(WorkState.path(dir, row.stamp))

      # Back on node A, the dump step is not A's to run.
      set_config(dir: dir)
      assert %{snoozed: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)

      set_config(dir: other)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert [%{status: :succeeded, stamp: stamp}] = runs()
      assert stamp == row.stamp
      assert Manifest.read(other).ok
    end
  end

  describe "a step whose node stopped (D9)" do
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

    defp beat!(node, boot_id, ago \\ 0) do
      Backups.beat_node!(%{node: node, boot_id: boot_id}, actor: Backups.system())

      if ago > 0 do
        Repo.update_all(from(b in "backup_node_beats", where: b.node == ^node),
          set: [beat_at: DateTime.add(DateTime.utc_now(), -ago, :second)]
        )
      end
    end

    test "a request reclaims a silent node's step only while the heartbeat is on" do
      {:ok, %{status: :started}} = request()
      job = current_job()
      {:ok, _lease} = Chain.begin_step(job)
      # No beat row at all, claimed 10 minutes ago: stale by the time rule.
      executing!(job, "silent@node", 600)

      # heartbeat?: false (the test build): no beats are ever written, so the
      # request must not judge the step dead; it queues behind it.
      refute Chain.heartbeat?()
      assert {:ok, %{status: :queued}} = request()
      assert %{state: "executing"} = Repo.get!(Oban.Job, job.id)

      original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :heartbeat?, true))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

      # With the heartbeat on, the same request reclaims it first.
      assert {:ok, %{status: :folded}} = request()
      assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)
    end

    test "killed during archive part 2: reclaimed, requeued with the budget left, same stamp, " <>
           "and the chain completes reusing the dump and part 1",
         %{dir: dir} do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("archive", 2)
      %{stamp: stamp, epoch: epoch} = lock()

      dump = Path.join([dir, "db", "kiln-db-#{stamp}.dump"])
      p1 = Path.join([dir, "media", Artifact.part_name(stamp, 1)])
      old = Map.new([dump, p1], &{&1, aged(&1)})

      # The node that took part 2 claimed the lock and then went silent.
      {:ok, zombie} = Chain.begin_step(job)
      executing!(job, "dead@node", 600)

      assert {:ok, {:requeued, %{job_id: new_id, stamp: ^stamp}}} = Chain.reclaim_stale()

      assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)
      assert %{max_attempts: 3, state: "available"} = Repo.get!(Oban.Job, new_id)
      row = lock()
      assert row.step_job_id == new_id and row.step == :archive and row.part == 2
      assert row.epoch > epoch
      assert row.stamp == stamp

      # The zombie wakes up: it can't move the chain on.
      assert {:error, :superseded} = Chain.advance(zombie, "archive", 3)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      for {path, at} <- old, do: assert(mtime(path) == at, "#{path} was rebuilt")
      assert [%{status: :succeeded, stamp: ^stamp}] = runs()
      assert Manifest.read(dir).ok
    end

    test "a fresh beat from the same boot is alive: nothing is reclaimed" do
      {:ok, %{status: :started}} = request()
      job = current_job()
      {:ok, _} = Chain.begin_step(job)
      executing!(job, "live@node", 600)
      beat!("live@node", Backups.boot_id())

      assert {:ok, :none} = Chain.reclaim_stale()
      assert lock().step_job_id == job.id
    end

    test "a fresh beat from a different boot of the node that claimed the step is reclaimed" do
      {:ok, %{status: :started}} = request()
      job = executing!(current_job(), "restarted@node", 5)
      {:ok, _} = Chain.begin_step(job)
      beat!("restarted@node", Ash.UUID.generate())

      assert {:ok, {:requeued, _}} = Chain.reclaim_stale()
    end

    test "a later attempt of the claimed job, on another node and not yet claimed, is not a " <>
           "restart; the beat's age decides" do
      {:ok, %{status: :started}} = request()
      job = current_job()

      # Attempt 1 claimed the lock on this boot, then failed.
      first = executing!(job, "a@node", 600)
      {:ok, _} = Chain.begin_step(first)

      # Attempt 2, fetched by node B (fresh beat, another boot) before it claims.
      executing!(first, "b@node", 5)
      beat!("b@node", Ash.UUID.generate())

      assert {:ok, :none} = Chain.reclaim_stale()
      assert lock().step_job_id == job.id
    end

    test "B4: another job's leftover boot id is not evidence; the beat's age decides" do
      {:ok, %{status: :started}} = request()
      job = current_job()
      # A previous job claimed it on boot A; this job runs on node B, not yet
      # claimed (`executing_job_id` is the old job's).
      Backups.mark_backup_lock_executing!(
        lock(),
        %{executing_boot_id: Ash.UUID.generate(), executing_job_id: job.id - 1},
        actor: Backups.system()
      )

      executing!(job, "b@node", 5)
      beat!("b@node", Ash.UUID.generate())

      assert {:ok, :none} = Chain.reclaim_stale()
    end

    test "no attempts left: the run fails as interrupted and the queued request is promoted" do
      {:ok, %{status: :started, chain: chain}} = request()
      step_until("dump")
      %{stamp: stamp} = lock()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      job = current_job()
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [attempt: 3])
      executing!(Repo.get!(Oban.Job, job.id), "gone@node", 600)
      beat!("gone@node", Ash.UUID.generate(), 600)

      assert {:ok, {:interrupted, %{promoted: promoted}}} = Chain.reclaim_stale()
      assert is_binary(promoted) and promoted != chain

      assert %{status: :failed, error: "Interrupted: node gone@node stopped responding"} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert %{chain: ^promoted, trigger: "schedule", waiting: nil} = Backups.in_flight()
    end
  end

  describe "a step job that ended without finishing (B3)" do
    test "a discarded holder job: the lock is released, the run fails, the waiter starts", %{
      dir: dir
    } do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("dump")
      %{stamp: stamp} = lock()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

      assert {:ok, {:orphaned, %{chain: ^chain, promoted: promoted}}} = Chain.reap()
      assert %{chain: ^promoted, trigger: "schedule"} = Backups.in_flight()

      run = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert run.status == :failed
      assert run.error =~ "Interrupted"

      # This node has the chain's directory and state: the failure manifest says so.
      refute Manifest.read(dir).ok
      assert Backups.run_resumable?(run)
    end

    test "a live holder job is left alone" do
      {:ok, %{status: :started}} = request()
      step_until("dump")
      assert {:ok, :none} = Chain.reap()
    end
  end

  describe "failures a retry can't fix" do
    test "state.json deleted mid-chain: the backup fails and the previous good manifest stays",
         %{dir: dir} do
      :ok =
        Manifest.write(dir, %Manifest{
          finished_at: DateTime.utc_now(),
          trigger: "cron",
          ok: true,
          artifacts: [%{kind: "db", path: "db/x.dump", bytes: 1, verified: true}]
        })

      before = File.read!(Manifest.path(dir))

      {:ok, %{status: :started, chain: chain}} = request()
      step_until("plan")
      %{stamp: stamp} = lock()
      File.rm!(WorkState.file(WorkState.path(dir, stamp)))

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert {:error, :no_state} = BackupChain.settled(chain)
      end)

      assert File.read!(Manifest.path(dir)) == before
      assert [%{status: :failed, error: error}] = runs()
      assert error =~ "state.json"
      assert Backups.in_flight() == nil
    end

    test "D7: a part changed between archive and checksum fails the backup at once, naming it; " <>
           "Resume rebuilds only that part",
         %{dir: dir} do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("checksum")
      %{stamp: stamp} = lock()
      [p1, p2, p3] = Enum.map(1..3, &Path.join([dir, "media", Artifact.part_name(stamp, &1)]))
      flip_byte!(p2)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert {:error, {:checksum_changed, [name]}} = BackupChain.settled(chain)
        assert name == Path.basename(p2)
      end)

      # Not retried.
      assert %{state: "cancelled", attempt: 1} = Repo.get!(Oban.Job, job.id)
      assert [%{status: :failed, error: error}] = runs()
      assert error =~ Path.basename(p2)
      refute Manifest.read(dir).ok

      old = Map.new([p1, p3], &{&1, aged(&1)})
      assert :ok = BackupChain.resume(stamp)

      for {path, at} <- old, do: assert(mtime(path) == at, "#{path} was rebuilt")
      assert {_, 0} = System.cmd("tar", ["-tzf", p2], stderr_to_stdout: true)
      assert [%{status: :succeeded}] = runs()
    end

    test "the last attempt's failure is terminal: the job is canceled and the lock released" do
      set_config(database_url: "postgres://nobody:nope@127.0.0.1:1/nope")

      {:ok, %{status: :started, chain: chain}} = request()

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert {:error, {:exit_status, "pg_dump", _, _}} = BackupChain.settled(chain)
      end)

      assert %Oban.Job{state: "cancelled", attempt: 4} =
               Enum.find(step_jobs(chain), &(&1.args["step"] == "dump"))

      assert Backups.in_flight() == nil
      assert [%{status: :failed}] = runs()
    end
  end

  describe "components (#2219)" do
    defp media_files(dir) do
      case File.ls(Path.join(dir, "media")) do
        {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, "kiln-media-"))
        {:error, _} -> []
      end
    end

    # A database the dump can't reach, and back.
    defp break_database! do
      url = Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Backups), :database_url)
      set_config(database_url: "postgres://nobody:nope@127.0.0.1:1/nope")
      fn -> set_config(database_url: url) end
    end

    defp dump_path(dir, stamp), do: Path.join([dir, "db", "kiln-db-#{stamp}.dump"])

    defp steps_run(chain), do: chain |> step_jobs() |> Enum.map(& &1.args["step"])

    # The queued request as an older node would leave it: `fun` bends the row
    # behind the new actions' back.
    defp bend_waiting!(set) do
      {1, _} = Repo.update_all(from(l in "backup_locks", where: l.name == "backups"), set: set)
    end

    test "a database-only backup dumps, never plans or archives, and says what it covered", %{
      dir: dir
    } do
      assert :ok = BackupChain.run("manual", components: [:db])

      assert [%{status: :succeeded, components: [:db], stamp: stamp, chain_id: chain} = run] =
               runs()

      steps = steps_run(chain)
      assert "dump" in steps
      refute Enum.any?(steps, &(&1 in ["plan", "archive", "checksum"]))

      assert Enum.map(run.artifacts, & &1.kind) == [:db]
      assert File.regular?(dump_path(dir, stamp))
      assert media_files(dir) == []
      assert Enum.any?(run.log, &(&1.message == "Backing up only: db"))

      manifest = Manifest.read(dir)
      assert manifest.ok
      assert manifest.components == ["db"]
    end

    test "a media-only backup skips the dump", %{dir: dir} do
      assert :ok = BackupChain.run("manual", components: [:media])

      assert [%{status: :succeeded, components: [:media], stamp: stamp} = run] = runs()
      assert Enum.map(run.artifacts, & &1.kind) == [:media]
      refute File.exists?(dump_path(dir, stamp))
      assert media_files(dir) != []

      assert %Manifest{ok: true, components: ["media"]} = Manifest.read(dir)
    end

    test "a database-only request folding into a queued media-only one widens it to both; " <>
           "a repeat leaves it as it is" do
      {:ok, %{status: :started, chain: first}} = request()
      {:ok, %{status: :queued}} = request(components: [:media])
      assert %{waiting: %{components: [:media], folds: 0}} = Backups.in_flight()

      {:ok, %{status: :folded}} = request(components: [:media])
      assert %{waiting: %{components: [:media], folds: 1}} = Backups.in_flight()

      {:ok, %{status: :folded}} = request(components: [:db])
      assert %{waiting: %{components: [:db, :media], folds: 2}} = Backups.in_flight()

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(first)
        assert_received {:chain_settled, second, :ok} when second != first
      end)

      assert [_first, %{components: [:db, :media], status: :succeeded}] =
               Enum.sort_by(runs(), & &1.stamp)
    end

    test "a promoted database-only request backs up the database only" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:db])

      BackupChain.drain()

      assert [%{components: [:db, :media]}, %{components: [:db], status: :succeeded}] =
               Enum.sort_by(runs(), & &1.stamp)
    end

    test "anything folding into a queued request for everything leaves it everything" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request()
      {:ok, %{status: :folded}} = request(components: [:db])

      assert %{waiting: %{components: nil, folds: 1}} = Backups.in_flight()
      assert Chain.waiting_scope(lock()).valid?
    end

    test "a queued request whose scope is an older node's is promoted as everything" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:db])

      # An older node's `:queue_waiting` sets `waiting_requested_at` and nothing
      # of the scope; the db-only list left over is not this request's.
      bend_waiting!(waiting_requested_at: DateTime.add(DateTime.utc_now(), 1, :second))
      refute Chain.waiting_scope(lock()).valid?
      assert %{waiting: %{components: nil}} = Backups.in_flight()

      BackupChain.drain()

      assert [_first, %{components: [:db, :media], status: :succeeded}] =
               Enum.sort_by(runs(), & &1.stamp)
    end

    # Critic amendment B-3: an older node's `:fold` bumps `waiting_folds` alone.
    test "a fold by an older node (only waiting_folds moved) makes the queued request everything" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:db])

      bend_waiting!(waiting_folds: 1)
      refute Chain.waiting_scope(lock()).valid?

      BackupChain.drain()

      assert [_first, %{components: [:db, :media], status: :succeeded}] =
               Enum.sort_by(runs(), & &1.stamp)
    end

    test "folding onto a scope that is not valid adopts everything, and the scope is valid again" do
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:db])
      bend_waiting!(waiting_folds: 1)

      {:ok, %{status: :folded}} = request(components: [:db])

      row = lock()
      assert row.waiting_folds == 2
      assert %{valid?: true, components: nil} = Chain.waiting_scope(row)
    end

    test "a resume is refused by a queued database-only request, which keeps its scope (#2540)",
         %{dir: dir} do
      restore = break_database!()
      assert {:error, _} = BackupChain.run()
      assert [%{status: :failed, stamp: failed}] = runs()
      assert WorkState.exists?(WorkState.path(dir, failed))
      restore.()

      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(components: [:db])
      assert {:error, {:queue_busy, :backup}} = request(resume: failed)

      assert %{waiting: %{components: [:db], resume: nil, folds: 0}} = Backups.in_flight()
    end

    # A failed database-only backup whose files are kept, ready to resume.
    defp failed_db_only! do
      restore = break_database!()
      assert {:error, _} = BackupChain.run("manual", components: [:db])
      restore.()
      [%{status: :failed, stamp: stamp, components: [:db]}] = runs()
      stamp
    end

    test "a queued resume of a database-only run refuses every fresh request, even one it " <>
           "covers, and writes nothing (#2540)" do
      stamp = failed_db_only!()
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)
      assert %{waiting: %{resume: ^stamp, components: [:db]}} = Backups.in_flight()

      before = lock()
      busy = {:queue_busy, {:resume, stamp}}
      assert {:error, ^busy} = request()
      assert {:error, ^busy} = request(components: [:media])
      assert {:error, ^busy} = request(components: [:db, :media])
      assert {:error, ^busy} = request(components: [:db])

      after_ = lock()

      for field <- [
            :waiting_folds,
            :waiting_components,
            :waiting_scope_at,
            :waiting_scope_folds,
            :last_folded_at,
            :epoch
          ] do
        assert Map.get(after_, field) == Map.get(before, field), "#{field} changed"
      end

      # A resume of the same stamp folds, and keeps the run's components.
      assert {:ok, %{status: :folded}} = request(resume: stamp)
      assert %{waiting: %{resume: ^stamp, components: [:db], folds: 1}} = Backups.in_flight()
    end

    test "a promoted resume backs up its run's components", %{dir: dir} do
      stamp = failed_db_only!()
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)

      BackupChain.drain()

      assert %{status: :succeeded, components: [:db]} =
               run =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert Enum.map(run.artifacts, & &1.kind) == [:db]
      refute Enum.any?(media_files(dir), &String.contains?(&1, stamp))
    end

    test "a resume an older node queued covers everything; still only its own resume folds " <>
           "into it" do
      stamp = failed_db_only!()
      {:ok, %{status: :started}} = request()
      {:ok, %{status: :queued}} = request(resume: stamp)
      bend_waiting!(waiting_folds: 1)

      assert {:error, {:queue_busy, {:resume, ^stamp}}} = request(components: [:media])
      assert {:error, {:queue_busy, {:resume, ^stamp}}} = request()
      assert {:ok, %{status: :folded}} = request(resume: stamp)
      assert %{waiting: %{resume: ^stamp, components: nil}} = Backups.in_flight()
    end

    test "media asked for on a node with no media directory is a skipped run; the manifest " <>
           "is left alone",
         %{dir: dir} do
      :ok =
        Manifest.write(dir, %Manifest{
          finished_at: DateTime.utc_now(),
          trigger: "cron",
          ok: true,
          artifacts: [%{kind: "db", path: "db/x.dump", bytes: 1, verified: true}]
        })

      before = File.read!(Manifest.path(dir))

      {:ok, %{status: :started, chain: chain}} = request(components: [:media])
      # The start step runs on a node configured without one.
      set_config(media_dir: nil)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert {:error, :no_media_dir} = BackupChain.settled(chain)
      end)

      assert [%{status: :skipped, components: [:media], error: "Refused: no_media_dir"}] = runs()
      assert File.read!(Manifest.path(dir)) == before
      assert Backups.in_flight() == nil
    end

    test "a resume of a failed database-only backup backs up the database only", %{dir: dir} do
      restore = break_database!()
      assert {:error, _} = BackupChain.run("manual", components: [:db])
      assert [%{status: :failed, stamp: stamp, components: [:db]}] = runs()
      restore.()

      assert :ok = BackupChain.resume(stamp)

      assert [%{status: :succeeded, components: [:db]} = run] = runs()
      assert Enum.map(run.artifacts, & &1.kind) == [:db]
      assert media_files(dir) == []
      assert %Manifest{ok: true, components: ["db"]} = Manifest.read(dir)
    end

    # Critic amendment B-2: the routing is the steps', so a resume follows it.
    test "a resume of a failed media-only backup never dumps the database", %{
      base: base,
      dir: dir,
      media: media
    } do
      set_config(media_dir: Path.join(base, "gone"))
      assert {:error, _} = BackupChain.run("manual", components: [:media])
      assert [%{status: :failed, stamp: stamp, components: [:media]}] = runs()
      refute File.exists?(dump_path(dir, stamp))
      set_config(media_dir: media)

      assert :ok = BackupChain.resume(stamp)

      assert [%{status: :succeeded, components: [:media]} = run] = runs()
      assert Enum.map(run.artifacts, & &1.kind) == [:media]
      refute File.exists?(dump_path(dir, stamp))
    end

    # Critic amendment B-2: a start retried after its state landed carries on
    # from the state, and the dump step routes past itself.
    test "a retried start of a media-only chain still skips the dump", %{dir: dir} do
      {:ok, %{status: :started, chain: chain}} = request(components: [:media])

      # The start step's hand-over to `dump` conflicts, after its state landed.
      {:ok, blocker} =
        Oban.insert(
          StepWorker.new(%{"chain" => chain, "step" => "dump", "part" => nil}, schedule_in: 3600)
        )

      assert %{failure: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      %{stamp: stamp, step: :start} = lock()

      assert {:ok, %{"components" => ["media"]}} =
               WorkState.read(WorkState.path(dir, stamp))

      Repo.delete!(blocker)

      BackupChain.listen(fn ->
        BackupChain.drain()
        assert :ok = BackupChain.settled(chain)
      end)

      assert [%{status: :succeeded, components: [:media], stamp: ^stamp}] = runs()
      refute File.exists?(dump_path(dir, stamp))
    end

    test "a request names its components or is refused before it touches the lock" do
      for bad <- [[], [:db, :db], [:files], ["nope"], :db, "db", %{}] do
        assert {:error, :invalid_components} = request(components: bad), inspect(bad)
      end

      assert {:error, :components_with_resume} =
               request(components: [:db], resume: "20260101-000000")

      set_config(media_dir: nil)
      assert {:error, :no_media_dir} = request(components: [:media])
      assert {:error, :no_media_dir} = request(components: [:db, :media])
      assert Backups.in_flight() == nil

      # Names do too, and nil is everything.
      assert {:ok, %{status: :started}} = request(components: ["db"])
      assert {:ok, %{status: :queued}} = request(components: nil)
    end

    test "the action refuses a repeated component on its own" do
      assert {:error, error} =
               Backups.request_backup(%{components: [:db, :db]}, actor: Backups.system())

      assert Enum.any?(error.errors, &match?(%Backups.Refused{reason: :invalid_components}, &1))
    end
  end

  describe "entry points (D8)" do
    test "Worker.run/3 requests a backup and waits for its chain", %{dir: dir} do
      task = Task.async(fn -> Worker.run("console", nil, interval: 50, timeout: 60_000) end)

      wait_until(fn -> Backups.in_flight() != nil end)
      BackupChain.drain()

      assert :ok = Task.await(task, 60_000)
      assert [%{status: :succeeded, trigger: "console"}] = runs()
      assert Manifest.read(dir).ok
    end

    test "Worker.run/3 while a backup runs queues and says so" do
      {:ok, %{status: :started}} = request()
      assert {:error, :queued} = Worker.run("console")
    end
  end

  describe "retention" do
    test "the prune step runs once per chain, before the off-site copy", %{base: base, dir: dir} do
      old = Path.join([dir, "db", "kiln-db-20190101-000000.dump"])
      newer = Path.join([dir, "db", "kiln-db-20200101-000000.dump"])
      File.mkdir_p!(Path.dirname(old))

      for path <- [old, newer] do
        File.write!(path, "old")
        File.touch!(path, System.os_time(:second) - 365 * 24 * 3600)
      end

      bin = Path.join(base, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "rclone"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "rclone"), 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
      set_config(rclone_remote: "r2:kiln")

      assert :ok = BackupChain.run()

      assert [%{log: log}] = Enum.filter(runs(), &(&1.origin == :app))
      steps = Enum.map(log, & &1.step)
      assert Enum.count(steps, &(&1 == "prune")) == 1
      prune_at = Enum.find_index(steps, &(&1 == "prune"))
      offsite_at = Enum.find_index(steps, &(&1 == "offsite"))
      assert prune_at < offsite_at
      refute File.exists?(old)
    end

    # #2219, critic amendment A-1: the marker lands when the run succeeds, not
    # at the next prune, so a run that fails in between can't leave cron a
    # newer complete set to keep instead of the verified one.
    test "a run that succeeds is marked last good at once, and cron's prune keeps it after a " <>
           "later run fails leaving a newer complete dump",
         %{base: base, dir: dir} do
      assert :ok = BackupChain.run()
      assert [%{stamp: good, status: :succeeded}] = runs()

      assert File.exists?(Path.join([dir, "db", Artifact.good_name(good)]))
      assert File.exists?(Path.join([dir, "media", Artifact.good_name(good)]))

      # The next run dumps the database, then fails planning the media.
      set_config(media_dir: Path.join(base, "gone"))
      assert {:error, _} = BackupChain.run()

      assert [%{stamp: failed, status: :failed}] =
               Enum.filter(runs(), &(&1.stamp != good))

      newer_dump = Path.join([dir, "db", "kiln-db-#{failed}.dump"])
      assert File.regular?(newer_dump) and File.stat!(newer_dump).size > 0
      assert failed > good

      # The failed run's `.work/<stamp>` keeps it in flight for a resume until
      # the sweep removes it (`Steps.sweep_work_dirs/2`, days later): gone here,
      # as it will be by the time its files are past BACKUP_KEEP_DAYS.
      assert File.dir?(Path.join([dir, ".work", failed]))
      File.rm_rf!(Path.join([dir, ".work", failed]))

      # Past BACKUP_KEEP_DAYS, everything: only the rules can keep a file now.
      long_ago = System.os_time(:second) - 30 * 24 * 3600

      for sub <- ["db", "media"],
          name <- File.ls!(Path.join(dir, sub)),
          do: File.touch!(Path.join([dir, sub, name]), long_ago)

      script = Path.expand("../../../scripts/backup.sh", __DIR__)

      assert {_out, 0} =
               System.cmd("bash", [script, "prune"],
                 env: [{"BACKUP_DIR", dir}, {"BACKUP_KEEP_DAYS", "14"}, {"MEDIA_DIR", nil}],
                 stderr_to_stdout: true
               )

      assert File.exists?(Path.join([dir, "db", "kiln-db-#{good}.dump"]))
      assert File.exists?(newer_dump)
    end
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end
end
