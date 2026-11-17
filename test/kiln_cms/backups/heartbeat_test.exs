defmodule KilnCMS.Backups.HeartbeatTest do
  @moduledoc """
  The per-node backup heartbeat (#2218, D9): each tick beats with the
  database's clock, frees the lock from a step whose node stopped or restarted
  (requeued with the budget left, or failed when there is none), releases a
  lock whose step job ended (B3), and fences this node's own steps when it
  cannot beat.

  Tick-driven: the test build starts no heartbeat process
  (`heartbeat?: false`), so each test calls `Heartbeat.tick/1` in its own
  process, inside its sandbox. `async: false`: it changes the VM-wide
  `Application` env and registers in the VM-wide `StepRegistry`.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, Fence, Heartbeat, StepWorker}
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupChain

  @moduletag :capture_log
  @moduletag :pg_tools

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bkh_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    %{dir: dir, state: Heartbeat.new_state(node: "this@node")}
  end

  defp request(opts \\ []), do: Backups.request(opts, Backups.system())

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp current_job, do: Repo.get!(Oban.Job, lock().step_job_id)

  defp beat_of(node), do: Backups.get_node_beat!(node, actor: Backups.system())

  # The start step, run; the lock now points at the dump step's job.
  defp at_dump do
    {:ok, %{status: :started, chain: chain}} = request()
    %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
    %{chain: chain, stamp: lock().stamp, job: current_job()}
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

  defp beat!(node, boot_id, ago \\ 0) do
    Backups.beat_node!(%{node: node, boot_id: boot_id}, actor: Backups.system())

    if ago > 0 do
      Repo.update_all(from(b in "backup_node_beats", where: b.node == ^node),
        set: [beat_at: DateTime.add(DateTime.utc_now(), -ago, :second)]
      )
    end
  end

  describe "the beat" do
    test "upserts this node's row with the database's now()", %{state: state} do
      state = Heartbeat.tick(state)
      %{rows: [[db_now]]} = Repo.query!("SELECT now()")

      beat = beat_of("this@node")
      # Inside the sandbox's transaction `now()` is the transaction's start:
      # equal only if the database, not this node, stamped the beat.
      assert DateTime.compare(beat.beat_at, db_now) == :eq

      assert beat.boot_id == state.boot_id
      assert is_integer(state.last_beat)

      # A later beat moves an old row's `beat_at` (the upsert's UPDATE).
      beat!("this@node", state.boot_id, 600)
      Heartbeat.tick(state)
      assert DateTime.compare(beat_of("this@node").beat_at, db_now) == :eq

      assert [_one] =
               Enum.filter(
                 Backups.list_node_beats!(actor: Backups.system()),
                 &(&1.node == "this@node")
               )
    end

    # #2543: a beat that reports no directory id clears the one before it, so
    # a node whose BACKUP_DIR lost its id stops being routed marker syncs.
    test "each beat's dir_id replaces the last one's, nil included; still one row" do
      boot = Ash.UUID.generate()
      [a, b] = [Ash.UUID.generate(), Ash.UUID.generate()]

      beat =
        &Backups.beat_node!(%{node: "this@node", boot_id: boot, dir_id: &1},
          actor: Backups.system()
        )

      beat.(a)
      assert beat_of("this@node").dir_id == a

      beat.(b)
      assert beat_of("this@node").dir_id == b

      Repo.update_all(from(n in "backup_node_beats", where: n.node == "this@node"),
        set: [beat_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

      old = beat_of("this@node").beat_at
      beat.(nil)

      assert %{dir_id: nil, beat_at: at} = beat_of("this@node")
      assert DateTime.after?(at, old)

      assert [_one] =
               Enum.filter(
                 Backups.list_node_beats!(actor: Backups.system()),
                 &(&1.node == "this@node")
               )
    end

    test "W9: a row another boot wrote since this node's last beat is logged as an error", %{
      state: state
    } do
      state = Heartbeat.tick(state)
      beat!("this@node", Ash.UUID.generate())

      log = capture_log([level: :error], fn -> Heartbeat.tick(state) end)
      assert log =~ "another node is beating as \"this@node\""
      assert log =~ "must be unique"
    end

    test "W9: the first beat after a restart is not an error (the row is this node's last boot)",
         %{state: state} do
      beat!("this@node", Ash.UUID.generate())

      log = capture_log([level: :error], fn -> Heartbeat.tick(state) end)
      refute log =~ "another node is beating"
    end
  end

  describe "the sweep" do
    test "a stale node: its job canceled, a replacement with the budget left, same stamp, " <>
           "epoch + 1",
         %{state: state} do
      %{stamp: stamp, job: job} = at_dump()
      {:ok, _zombie} = Chain.begin_step(job)
      executing!(job, "dead@node", 600)
      beat!("dead@node", Backups.boot_id(), 600)
      epoch = lock().epoch

      Heartbeat.tick(state)

      assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)
      row = lock()
      assert row.step_job_id != job.id and row.step == :dump
      assert row.stamp == stamp
      assert row.epoch == epoch + 1
      assert %{state: "available", max_attempts: 3} = Repo.get!(Oban.Job, row.step_job_id)
    end

    test "a node that restarted (its beat has another boot id) is reclaimed", %{state: state} do
      %{job: job} = at_dump()
      job = executing!(job, "restarted@node", 5)
      {:ok, _} = Chain.begin_step(job)
      beat!("restarted@node", Ash.UUID.generate())

      Heartbeat.tick(state)

      assert %{state: "cancelled"} = Repo.get!(Oban.Job, job.id)
      assert lock().step_job_id != job.id
    end

    test "B4: a leftover boot id of another job is not a restart; a fresh beat keeps the step",
         %{state: state} do
      %{job: job} = at_dump()

      Backups.mark_backup_lock_executing!(
        lock(),
        %{executing_boot_id: Ash.UUID.generate(), executing_job_id: job.id - 1},
        actor: Backups.system()
      )

      executing!(job, "b@node", 5)
      beat!("b@node", Ash.UUID.generate())

      Heartbeat.tick(state)

      assert lock().step_job_id == job.id
      assert %{state: "executing"} = Repo.get!(Oban.Job, job.id)
    end

    test "budget exhausted: the run fails, the lock is released, the queued request starts", %{
      state: state
    } do
      %{chain: chain, stamp: stamp, job: job} = at_dump()
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [attempt: 3])
      executing!(Repo.get!(Oban.Job, job.id), "gone@node", 600)
      beat!("gone@node", Ash.UUID.generate(), 600)

      Heartbeat.tick(state)

      assert %{status: :failed, error: "Interrupted: node gone@node stopped responding"} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert %{chain: promoted, trigger: "schedule", waiting: nil} = Backups.in_flight()
      assert promoted != chain
    end

    test "B3: a discarded holder job: the lock is released, the run fails, the waiter starts", %{
      state: state
    } do
      %{chain: chain, stamp: stamp, job: job} = at_dump()
      {:ok, %{status: :queued}} = request(trigger: "schedule")
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])

      Heartbeat.tick(state)

      run = Backups.get_run_by_stamp!(stamp, actor: Backups.system())
      assert run.status == :failed
      assert run.error =~ "Interrupted"
      assert %{chain: promoted, trigger: "schedule"} = Backups.in_flight()
      assert promoted != chain
    end

    test "a live step is left alone", %{state: state} do
      %{job: job} = at_dump()
      {:ok, _} = Chain.begin_step(job)
      executing!(job, "this@node", 600)

      # This node's own beat, this boot: the tick itself beats.
      Heartbeat.tick(%{state | boot_id: Backups.boot_id()})

      assert lock().step_job_id == job.id
      assert %{state: "executing"} = Repo.get!(Oban.Job, job.id)
    end
  end

  describe "self-fence" do
    test "no successful beat for 90 s kills the registered step processes", %{state: state} do
      parent = self()

      step =
        spawn(fn ->
          {:ok, _} = Registry.register(KilnCMS.Backups.StepRegistry, "chain", "archive")
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      ref = Process.monitor(step)

      stale = %{state | last_beat: System.monotonic_time(:millisecond) - 91_000}

      # The beat itself is refused (no grant): the node can't prove it's alive.
      log =
        capture_log([level: :error], fn ->
          Backups.with_actor(nil, fn -> Heartbeat.tick(stale) end)
        end)

      assert_receive {:DOWN, ^ref, :process, ^step, :killed}
      assert log =~ "stopping 1 backup step"
    end

    test "a recent successful beat kills nothing", %{state: state} do
      parent = self()

      step =
        spawn(fn ->
          {:ok, _} = Registry.register(KilnCMS.Backups.StepRegistry, "chain", "archive")
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(step, :kill) end)

      fresh = %{state | last_beat: System.monotonic_time(:millisecond) - 60_000}
      Backups.with_actor(nil, fn -> Heartbeat.tick(fresh) end)

      assert Process.alive?(step)
    end
  end

  # #2848: the tick does file I/O on BACKUP_DIR, which a hung mount blocks, so
  # the fence also runs in a watchdog of its own.
  describe "the fence watchdog" do
    defp sleeping_step do
      parent = self()

      step =
        spawn(fn ->
          {:ok, _} = Registry.register(KilnCMS.Backups.StepRegistry, "chain", "archive")
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(step, :kill) end)
      {step, Process.monitor(step)}
    end

    test "kills the registered steps when the heartbeat is stuck after a beat", %{dir: dir} do
      File.mkdir_p!(dir)
      start_supervised!({Fence, fence_after_ms: 300, check_ms: 20})

      heartbeat =
        start_supervised!({Heartbeat, name: :fence_test_heartbeat, node: "stuck@node"})

      # Its first tick beat (the row is there), then it hangs.
      :sys.get_state(heartbeat)
      assert beat_of("stuck@node")
      :ok = :sys.suspend(heartbeat)

      {step, ref} = sleeping_step()

      log =
        capture_log([level: :error], fn ->
          assert_receive {:DOWN, ^ref, :process, ^step, :killed}, 2_000
        end)

      assert log =~ "stopping 1 backup step"
      assert Process.alive?(heartbeat)
    end

    test "kills nothing while beats keep coming" do
      fence =
        start_supervised!({Fence, name: :fence_test_fresh, fence_after_ms: 300, check_ms: 20})

      {step, ref} = sleeping_step()

      for _ <- 1..15 do
        Fence.beat(fence, System.monotonic_time(:millisecond))
        Process.sleep(40)
      end

      refute_received {:DOWN, ^ref, :process, ^step, _}
      assert Process.alive?(step)
    end

    test "ignores stray messages" do
      fence = start_supervised!({Fence, name: :fence_test_stray})
      send(fence, {make_ref(), :late})
      send(fence, :whatever)
      assert %{last_beat: _} = :sys.get_state(fence)
    end
  end

  # #2848: the backup-directory id is read in a task the tick waits on for a
  # short while only, and never more than one at a time.
  describe "a backup-directory id read that hangs" do
    # Every read announces itself and blocks until released with its answer.
    defp blocking_reader!(timeout_ms \\ 50) do
      parent = self()

      reader = fn _dir, _ensure? ->
        send(parent, {:reader, self()})

        receive do
          {:release, result} -> result
        end
      end

      # A failed test must not leave a blocked read to the next one.
      on_exit(fn -> Enum.each(readers(), &Process.exit(&1, :kill)) end)
      put_backups_env(dir_id_reader: reader, dir_id_timeout_ms: timeout_ms)
    end

    defp put_backups_env(opts) do
      env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(env, opts))
    end

    defp release(reader, result) do
      ref = Process.monitor(reader)
      send(reader, {:release, result})
      assert_receive {:DOWN, ^ref, :process, ^reader, _}
    end

    defp readers, do: Task.Supervisor.children(KilnCMS.Backups.DirIdReaders)

    # A directory that holds backups and has an id, read once for real.
    defp read_once!(dir, state) do
      File.mkdir_p!(Path.join(dir, "db"))
      {:ok, id} = DirId.local(dir)
      state = Heartbeat.tick(state)
      assert beat_of(state.node).dir_id == id
      {id, state}
    end

    test "the tick returns within the timeout and beats with no id when none was read", %{
      state: state
    } do
      blocking_reader!()

      {micros, {state, log}} =
        :timer.tc(fn -> with_log([level: :warning], fn -> Heartbeat.tick(state) end) end)

      assert micros < 2_000_000
      assert %{beat_ok?: true, dir_id_task: %{}} = state
      assert beat_of("this@node").dir_id == nil
      assert log =~ "has taken more than"

      assert_received {:reader, reader}
      release(reader, {:error, :enoent})
    end

    test "beats with no id while a read is held up, though an id was read before", %{
      dir: dir,
      state: state
    } do
      {id, state} = read_once!(dir, state)
      blocking_reader!()

      {state, first} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)
      assert beat_of("this@node").dir_id == nil
      assert first =~ "Beating with no id"

      # Still hung: still no id, and one warning per stall.
      {state, second} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)
      assert beat_of("this@node").dir_id == nil
      assert second == ""

      # It answers: the next tick reports the id again.
      assert_received {:reader, reader}
      release(reader, {:ok, id})
      state = Heartbeat.tick(state)
      assert beat_of("this@node").dir_id == id
      assert %{dir_id_task: nil, dir_id_stalled?: false} = state
    end

    test "single-flight: ticks while a read hangs start no other read", %{state: state} do
      blocking_reader!()

      state = state |> Heartbeat.tick() |> Heartbeat.tick() |> Heartbeat.tick()

      assert_received {:reader, reader}
      refute_received {:reader, _}
      assert readers() == [reader]
      assert state.dir_id_task.pid == reader

      release(reader, {:error, :enoent})
    end

    test "a read that finishes late is used by the next tick; no task is left", %{
      state: state
    } do
      blocking_reader!()
      state = Heartbeat.tick(state)
      assert_received {:reader, reader}

      fresh = Ash.UUID.generate()
      release(reader, {:ok, fresh})
      refute Process.alive?(reader)

      state = Heartbeat.tick(state)
      assert beat_of("this@node").dir_id == fresh
      assert %{dir_id_task: nil, dir_id_stalled?: false} = state
      # The answer came in: no new read was needed for this beat.
      refute_received {:reader, _}
      assert readers() == []
    end

    test "a read that crashes reports no id", %{dir: dir, state: state} do
      {_id, state} = read_once!(dir, state)
      put_backups_env(dir_id_reader: fn _dir, _ensure? -> raise "boom" end)

      state = Heartbeat.tick(state)

      assert %{beat_ok?: true, dir_id_task: nil} = state
      assert beat_of("this@node").dir_id == nil
    end

    test "a read that answers something unexpected reports no id and ends the read", %{
      dir: dir,
      state: state
    } do
      {_id, state} = read_once!(dir, state)
      put_backups_env(dir_id_reader: fn _dir, _ensure? -> :unexpected end)

      {state, log} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)

      assert %{beat_ok?: true, dir_id_task: nil} = state
      assert beat_of("this@node").dir_id == nil
      assert log =~ "unexpected answer :unexpected"
      assert readers() == []
    end

    test "an error in the id read is logged and the beat still goes out", %{state: state} do
      # Waiting on the read raises (an invalid `after` timeout).
      put_backups_env(dir_id_reader: fn _dir, _ensure? -> {:error, :enoent} end)
      put_backups_env(dir_id_timeout_ms: :not_a_timeout)
      on_exit(fn -> Enum.each(readers(), &Process.exit(&1, :kill)) end)

      {state, log} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)

      assert %{beat_ok?: true} = state
      assert beat_of("this@node").dir_id == nil
      assert log =~ "the backup-directory id read failed, beating with no id"
    end

    test "with the readers full, a tick starts none and beats with no id", %{state: state} do
      blocking_reader!()

      # Four heartbeats (restarted ones, say) each hold a hung read: the
      # supervisor's limit.
      [first | others] =
        for n <- 1..4 do
          held = Heartbeat.tick(Heartbeat.new_state(node: "held-#{n}@node"))
          assert_received {:reader, reader}
          assert held.dir_id_task.pid == reader
          reader
        end

      {state, log} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)

      refute_received {:reader, _}
      assert %{beat_ok?: true, dir_id_task: nil, readers_full?: true} = state
      assert beat_of("this@node").dir_id == nil
      assert log =~ "maximum number of tasks"
      assert length(readers()) == 4

      # One warning while full.
      {state, again} = with_log([level: :warning], fn -> Heartbeat.tick(state) end)
      assert again == ""

      # Room again: the next tick reads.
      release(first, {:error, :enoent})
      state = Heartbeat.tick(state)
      assert_received {:reader, third}
      assert %{readers_full?: false, dir_id_task: %{pid: ^third}} = state

      Enum.each([third | others], &release(&1, {:error, :enoent}))
      assert readers() == []
    end

    test "the read's late answer reaches the running heartbeat; stray messages are ignored", %{
      state: state
    } do
      blocking_reader!()
      state = Heartbeat.tick(state)
      assert_received {:reader, reader}
      %{ref: ref} = state.dir_id_task

      fresh = Ash.UUID.generate()
      release(reader, {:ok, fresh})
      # What the GenServer would get between ticks: the reply, then nothing
      # (its monitor is flushed).
      assert_received {^ref, {:ok, ^fresh}}

      assert {:noreply, %{dir_id_task: nil, dir_id_stalled?: false} = after_reply} =
               Heartbeat.handle_info({ref, {:ok, fresh}}, state)

      # A duplicate reply, a stale :DOWN and anything else change nothing.
      for message <- [
            {ref, {:ok, Ash.UUID.generate()}},
            {:DOWN, ref, :process, reader, :normal},
            {make_ref(), :late},
            :unexpected
          ] do
        assert Heartbeat.handle_info(message, after_reply) == {:noreply, after_reply}
      end

      # A :DOWN for the read in flight ends it with no new id.
      blocking_reader!()
      state = Heartbeat.tick(after_reply)
      assert_received {:reader, second}
      %{ref: second_ref} = state.dir_id_task

      assert {:noreply, %{dir_id_task: nil}} =
               Heartbeat.handle_info({:DOWN, second_ref, :process, second, :killed}, state)

      release(second, {:error, :enoent})
    end
  end

  describe "stopping steps whose job was canceled (#2538)" do
    # A process registered as a step is, under `value`, as `StepWorker`
    # registers one; monitored, and killed at the end if still alive.
    defp registered_step(value) do
      parent = self()

      step =
        spawn(fn ->
          {:ok, _} = Registry.register(KilnCMS.Backups.StepRegistry, "chain", value)
          send(parent, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(step, :kill) end)
      {step, Process.monitor(step)}
    end

    defp step_job!(state) do
      job =
        Oban.insert!(
          StepWorker.new(%{
            "chain" => Ash.UUID.generate(),
            "step" => "archive",
            "part" => 1,
            "stamp" => "20260101-000000",
            "dir" => Ash.UUID.generate()
          })
        )

      {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
      job
    end

    for job_state <- ["cancelled", "completed", "discarded"] do
      test "a step whose job is #{job_state} is killed after a successful beat", %{state: state} do
        job = step_job!(unquote(job_state))
        {step, ref} = registered_step({"archive", job.id})

        log = capture_log([level: :error], fn -> Heartbeat.tick(state) end)

        assert_receive {:DOWN, ^ref, :process, ^step, :killed}
        assert log =~ "stopping 1 backup step(s) whose job was canceled"
      end
    end

    test "a step whose job row is missing keeps running (a lagging standby, a restore)", %{
      state: state
    } do
      job = step_job!("executing")
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
      {step, _ref} = registered_step({"archive", job.id})

      Heartbeat.tick(state)

      refute_receive {:DOWN, _, :process, ^step, _}, 100
      assert Process.alive?(step)
    end

    test "a step whose job is executing keeps running", %{state: state} do
      job = step_job!("executing")
      {step, _ref} = registered_step({"archive", job.id})

      Heartbeat.tick(state)

      refute_receive {:DOWN, _, :process, ^step, _}, 100
      assert Process.alive?(step)
    end

    test "a step registered by name alone (before #2538) is left to the fence", %{state: state} do
      {step, _ref} = registered_step("archive")

      Heartbeat.tick(state)

      refute_receive {:DOWN, _, :process, ^step, _}, 100
      assert Process.alive?(step)
    end

    test "no check when the beat fails: the job states may be anyone's guess", %{state: state} do
      job = step_job!("cancelled")
      {step, _ref} = registered_step({"archive", job.id})

      fresh = %{state | last_beat: System.monotonic_time(:millisecond) - 60_000}
      Backups.with_actor(nil, fn -> Heartbeat.tick(fresh) end)

      refute_receive {:DOWN, _, :process, ^step, _}, 100
      assert Process.alive?(step)
    end
  end

  describe "pruning" do
    test "the first tick prunes beats of nodes gone for a day", %{state: state} do
      beat!("old@node", Ash.UUID.generate(), 2 * 24 * 3600)
      beat!("recent@node", Ash.UUID.generate(), 60)

      Heartbeat.tick(state)

      nodes = Enum.map(Backups.list_node_beats!(actor: Backups.system()), & &1.node)
      refute "old@node" in nodes
      assert "recent@node" in nodes
    end
  end
end
