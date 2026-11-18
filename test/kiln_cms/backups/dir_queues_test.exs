defmodule KilnCMS.Backups.DirQueuesTest do
  @moduledoc """
  One Oban queue per backup directory (#2845): its name, the capability a
  node advertises in its beat, the heartbeat that runs the queue, routing a
  job into it (on insert and on fetch), and the sweeps for a job left in a
  queue no node runs.

  The heartbeat's queue calls go to `KilnCMS.Test.DirQueueControl` (the
  test build's control), which records them per test. `async: false`: it
  points the VM-wide backup directory at temporary ones.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Chain, DirId, DirQueues, Heartbeat, MarkerSyncWorker, StepWorker}
  alias KilnCMS.Repo
  alias KilnCMS.Test.{BackupChain, BackupCluster, DirQueueControl}

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_bdq_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    b = Path.join(base, "backups-b")
    media = Path.join(base, "media")
    File.mkdir_p!(media)
    for n <- 1..2, do: File.write!(Path.join(media, "f#{n}.bin"), :crypto.strong_rand_bytes(300))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: media, keep_days: 14)
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      File.rm_rf!(base)
    end)

    {:ok, a_id} = DirId.local(dir)
    {:ok, b_id} = DirId.local(b)

    %{base: base, dir: dir, b: b, a_id: a_id, b_id: b_id, qa: DirQueues.name(a_id)}
  end

  # -- helpers ---------------------------------------------------------------

  defp put_config(overrides) do
    env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(env, overrides))
  end

  # Two ticks of the node with directory `dir`: the first starts its queue,
  # the second's beat advertises it. Returns the heartbeat state.
  defp advertise!(dir, node) do
    state = BackupCluster.tick_as(dir, node)
    BackupCluster.tick_as(dir, state)
  end

  defp beat!(node, attrs) do
    Backups.beat_node!(Map.merge(%{node: node, boot_id: Ash.UUID.generate()}, attrs),
      actor: Backups.system()
    )
  end

  defp dump_args(dir_id) do
    %{
      "chain" => Ash.UUID.generate(),
      "step" => "dump",
      "part" => nil,
      "stamp" => "20260101-000000",
      "dir" => dir_id
    }
  end

  defp job(id), do: Repo.get!(Oban.Job, id)

  # Put job `id` in `queue`, waiting since `waited_s` seconds ago by the
  # database's clock.
  defp park!(id, queue, waited_s, state \\ "available") do
    Repo.query!(
      "UPDATE oban_jobs SET queue = $2, state = $3, " <>
        "scheduled_at = now() - make_interval(secs => $4) WHERE id = $1",
      [id, queue, state, waited_s]
    )

    :ok
  end

  defp lock, do: Backups.backup_lock!(actor: Backups.system())

  defp request(opts \\ []), do: Backups.request(opts, Backups.system())

  # Run the chain's jobs one at a time until the lock points at `step`.
  defp step_until(step) do
    row = lock()

    if to_string(row.step) == step do
      job(row.step_job_id)
    else
      %{success: 1} = BackupChain.drain(with_recursion: false, with_scheduled: false)
      step_until(step)
    end
  end

  defp attach(events) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach_many(
      id,
      events,
      fn event, _measurements, metadata, _ -> send(test, {:telemetry, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # -- names -----------------------------------------------------------------

  describe "names" do
    test "a queue is named only for a directory id, and gives the id back" do
      id = Ash.UUID.generate()
      queue = "backup_dir_" <> id

      assert DirQueues.name(id) == queue
      assert DirQueues.dir_id(queue) == id
      assert DirQueues.dir_queue?(queue)

      for bad <- [nil, "", "x", String.upcase(id), id <> "\n", "../" <> id, 42] do
        assert DirQueues.name(bad) == nil, "#{inspect(bad)} named a queue"
      end

      refute DirQueues.dir_queue?("backup_steps")
      refute DirQueues.dir_queue?("backup_dir_nope")
      refute DirQueues.dir_queue?(nil)
    end
  end

  # -- the capability --------------------------------------------------------

  describe "routable?/1: the capability a beat advertises (B1)" do
    test "a live node that reports the id and advertises its queue in this boot routes it" do
      id = Ash.UUID.generate()
      boot = Ash.UUID.generate()
      beat!("a@host", %{boot_id: boot, dir_id: id, dir_queue: id, dir_queue_boot_id: boot})

      assert DirQueues.routable?(id)
      assert {:ok, :advertised} = DirQueues.status(id)
    end

    test "an advertisement left by an earlier boot is no claim: an older node beat over it" do
      id = Ash.UUID.generate()
      boot = Ash.UUID.generate()
      beat!("a@host", %{boot_id: boot, dir_id: id, dir_queue: id, dir_queue_boot_id: boot})

      # A release from before #2845 restarts under the same name: its beat
      # writes the boot and the id, never the two new columns.
      Repo.query!("UPDATE backup_node_beats SET boot_id = $2 WHERE node = $1", [
        "a@host",
        Ecto.UUID.dump!(Ash.UUID.generate())
      ])

      assert %{dir_queue: ^id} = BackupCluster.beat_of("a@host")
      refute DirQueues.routable?(id)
      assert {:ok, :reported} = DirQueues.status(id)
    end

    test "reporting the id without advertising it, or advertising another, doesn't route" do
      id = Ash.UUID.generate()
      other = Ash.UUID.generate()
      boot = Ash.UUID.generate()
      beat!("a@host", %{dir_id: id})
      beat!("b@host", %{boot_id: boot, dir_id: id, dir_queue: other, dir_queue_boot_id: boot})
      beat!("c@host", %{boot_id: boot, dir_id: other, dir_queue: id, dir_queue_boot_id: boot})

      refute DirQueues.routable?(id)
      assert {:ok, :reported} = DirQueues.status(id)
      assert {:ok, :none} = DirQueues.status(Ash.UUID.generate())
    end

    test "a beat 181 s old doesn't route, 179 s does" do
      id = Ash.UUID.generate()
      boot = Ash.UUID.generate()
      beat!("a@host", %{boot_id: boot, dir_id: id, dir_queue: id, dir_queue_boot_id: boot})

      BackupCluster.backdate_beat!("a@host", 179)
      assert DirQueues.routable?(id)

      BackupCluster.backdate_beat!("a@host", 181)
      refute DirQueues.routable?(id)
      assert {:ok, :none} = DirQueues.status(id)
    end

    test "beats that can't be read don't route" do
      put_config(live_beats_reader: fn _within_s -> {:error, :connection_refused} end)
      id = Ash.UUID.generate()

      refute DirQueues.routable?(id)
      assert {:error, :connection_refused} = DirQueues.status(id)
      refute DirQueues.routable?(nil)
    end
  end

  # -- the heartbeat ---------------------------------------------------------

  describe "the heartbeat runs its directory's queue" do
    test "starts it once and advertises it on the next beat", %{dir: dir, a_id: id, qa: qa} do
      attach([[:kiln_cms, :backups, :dir_queue, :started]])

      first = BackupCluster.tick_as(dir, "a@host")
      assert DirQueueControl.calls() == [{:start, qa}]
      assert DirQueueControl.status(qa) == :running
      assert first.dir_queues.advertised == id
      assert_received {:telemetry, _, %{queue: ^qa, node: "a@host"}}

      # That tick's beat went out before the queue ran.
      assert %{dir_queue: nil} = BackupCluster.beat_of("a@host")
      refute DirQueues.routable?(id)

      second = BackupCluster.tick_as(dir, first)
      assert DirQueueControl.calls() == [{:start, qa}]
      boot = second.boot_id
      assert %{dir_queue: ^id, dir_queue_boot_id: ^boot} = BackupCluster.beat_of("a@host")
      assert DirQueues.routable?(id)
      refute_received {:telemetry, _, _}
    end

    test "another id read: the old queue is paused at once and the new one started", %{
      dir: dir,
      qa: qa
    } do
      attach([[:kiln_cms, :backups, :dir_queue, :paused]])
      state = advertise!(dir, "a@host")

      new = Ash.UUID.generate()
      File.write!(DirId.path(dir), new <> "\n")
      state = BackupCluster.tick_as(dir, state)

      qn = DirQueues.name(new)
      assert DirQueueControl.calls() == [{:start, qa}, {:pause, qa}, {:start, qn}]
      assert DirQueueControl.status(qa) == :paused
      assert state.dir_queues.advertised == new
      assert_received {:telemetry, _, %{queue: ^qa, reason: :changed}}

      BackupCluster.tick_as(dir, state)
      assert DirQueues.routable?(new)
    end

    test "no id: the queue runs on for 180 s, then is paused; it resumes when the id is back", %{
      dir: dir,
      a_id: id,
      qa: qa
    } do
      attach([[:kiln_cms, :backups, :dir_queue, :paused]])
      state = advertise!(dir, "a@host")
      File.rm!(DirId.path(dir))

      state = BackupCluster.tick_as(dir, state)
      assert DirQueueControl.calls() == [{:start, qa}]
      assert state.dir_queues.advertised == nil
      # The beat carries no id: nothing routes there.
      refute DirQueues.routable?(id)

      # 180 s later, by the heartbeat's monotonic clock.
      state = update_in(state.dir_queues.absent_since, &(&1 - 180_001))
      state = BackupCluster.tick_as(dir, state)
      assert DirQueueControl.calls() == [{:start, qa}, {:pause, qa}]
      assert DirQueueControl.status(qa) == :paused
      assert_received {:telemetry, _, %{queue: ^qa, reason: :gone}}

      File.write!(DirId.path(dir), id <> "\n")
      state = BackupCluster.tick_as(dir, state)
      assert DirQueueControl.calls() == [{:start, qa}, {:pause, qa}, {:resume, qa}]
      assert state.dir_queues.advertised == id
      assert state.dir_queues.absent_since == nil
    end

    test "a queue is paused, never stopped, whatever runs in it", %{dir: dir} do
      state = advertise!(dir, "a@host")
      File.write!(DirId.path(dir), Ash.UUID.generate() <> "\n")
      BackupCluster.tick_as(dir, state)

      assert Enum.all?(DirQueueControl.calls(), fn {call, _} -> call in [:start, :pause] end)
    end

    test "a failed beat changes nothing", %{dir: dir} do
      # A node name over the beat's limit: the beat is refused.
      node = String.duplicate("n", KilnCMS.Limits.identifier() + 1)
      state = BackupCluster.tick_as(dir, node)

      refute state.beat_ok?
      assert DirQueueControl.calls() == []
    end

    test "a restarted heartbeat finds its queue running and advertises it, starting nothing", %{
      dir: dir,
      a_id: id,
      qa: qa
    } do
      advertise!(dir, "a@host")

      restarted =
        BackupCluster.tick_as(
          dir,
          Heartbeat.new_state(node: "a@host", boot_id: Ash.UUID.generate())
        )

      assert DirQueueControl.calls() == [{:start, qa}]
      assert restarted.dir_queues.advertised == id

      # The restarted boot's first beat claimed nothing.
      refute DirQueues.routable?(id)
      restarted = BackupCluster.tick_as(dir, restarted)
      boot = restarted.boot_id
      assert %{dir_queue_boot_id: ^boot} = BackupCluster.beat_of("a@host")
      assert DirQueues.routable?(id)
    end

    test "a start that doesn't take (the notifier is down): one warning, never advertised", %{
      dir: dir,
      a_id: id,
      qa: qa
    } do
      DirQueueControl.refuse_starts(true)
      attach([[:kiln_cms, :backups, :dir_queue, :start_failed]])

      log =
        capture_log([level: :warning], fn ->
          Enum.reduce(1..5, "a@host", fn _, state -> BackupCluster.tick_as(dir, state) end)
        end)

      assert [_one] = Regex.scan(~r/Backup directory queue #{qa} hasn't started/, log)
      assert log =~ "jobs for its backup directory stay in backup_steps"
      assert_received {:telemetry, _, %{queue: ^qa}}
      refute_received {:telemetry, _, _}
      assert Enum.all?(DirQueueControl.calls(), &(&1 == {:start, qa}))
      assert %{dir_queue: nil} = BackupCluster.beat_of("a@host")
      refute DirQueues.routable?(id)
    end

    test "with directory queues off it leaves Oban's queues alone", %{dir: dir, a_id: id} do
      put_config(dir_queues?: false)
      advertise!(dir, "a@host")

      assert DirQueueControl.calls() == []
      assert %{dir_id: ^id, dir_queue: nil} = BackupCluster.beat_of("a@host")
    end

    test "a heartbeat that starts picks up the directory queues already running here", %{qa: qa} do
      DirQueueControl.put_status(qa, :paused)
      DirQueueControl.put_status("default", :running)

      assert DirQueues.seeded_state().queues == %{qa => :paused}
    end
  end

  # -- uniqueness ------------------------------------------------------------

  describe "uniqueness across queues" do
    test "a step moved to its directory's queue still counts", %{a_id: id, qa: qa} do
      args = dump_args(id)
      {:ok, %{conflict?: false} = first} = Oban.insert(StepWorker.new(args))
      park!(first.id, qa, 0)

      assert {:ok, %{conflict?: true}} = Oban.insert(StepWorker.new(args))
    end

    test "a marker sync moved to its directory's queue still counts", %{a_id: id, qa: qa} do
      {:ok, %{conflict?: false} = first} = Oban.insert(MarkerSyncWorker.new(%{"dir" => id}))
      park!(first.id, qa, 0)

      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => id}))
      # The cron slot and a schedule change still go to `default`.
      assert {:ok, %{queue: "default"}} = Oban.insert(MarkerSyncWorker.new(%{}))
    end
  end

  # -- routing on fetch ------------------------------------------------------

  describe "routing a job a node without its directory fetched" do
    # M2: an older node inserted a pinned step into backup_steps.
    test "it is moved in place: same job, no attempt spent, and the directory's node runs it", %{
      dir: dir,
      b: b,
      qa: qa,
      a_id: id
    } do
      attach([[:kiln_cms, :backups, :dir_queue, :routed]])
      advertise!(dir, "a@host")
      {:ok, inserted} = Oban.insert(StepWorker.new(dump_args(id)))
      assert inserted.queue == "backup_steps"

      assert [%{snoozed: 1}] = BackupCluster.drain_as(b, ["backup_steps"])

      assert %{queue: ^qa, state: "scheduled", attempt: 0, meta: %{"snoozed" => 1}} =
               job(inserted.id)

      assert_received {:telemetry, _, %{queue: ^qa, from: "backup_steps"}}

      # Node A: past the affinity check; not the lock's job, so superseded.
      assert [%{cancelled: 1}] = BackupCluster.drain_as(dir, [qa])
      assert %{state: "cancelled", attempt: 1} = job(inserted.id)
    end

    test "with no node advertising the queue it snoozes in backup_steps, as before", %{
      dir: dir,
      b: b,
      a_id: id
    } do
      # A reports the directory; its first beat advertises no queue yet.
      BackupCluster.tick_as(dir, "a@host")
      {:ok, inserted} = Oban.insert(StepWorker.new(dump_args(id)))

      assert [%{snoozed: 1}] = BackupCluster.drain_as(b, ["backup_steps"])
      assert %{queue: "backup_steps", meta: %{"snoozed" => 1}} = job(inserted.id)
    end

    test "with directory queues off it snoozes, even where a queue is advertised", %{
      dir: dir,
      b: b,
      a_id: id
    } do
      advertise!(dir, "a@host")
      put_config(dir_queues?: false)
      {:ok, inserted} = Oban.insert(StepWorker.new(dump_args(id)))

      assert [%{snoozed: 1}] = BackupCluster.drain_as(b, ["backup_steps"])
      assert %{queue: "backup_steps"} = job(inserted.id)
    end

    # M4: canceled between the fetch and the move.
    test "a job no longer this execution's is not moved", %{dir: dir, b: b, a_id: id} do
      advertise!(dir, "a@host")
      {:ok, inserted} = Oban.insert(StepWorker.new(dump_args(id)))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^inserted.id), set: [state: "cancelled"])

      fetched = %{inserted | state: "executing", attempt: 1, attempted_at: DateTime.utc_now()}

      assert {:cancel, :superseded} =
               BackupCluster.as_node(b, fn -> StepWorker.perform(fetched) end)

      assert %{queue: "backup_steps", state: "cancelled"} = job(inserted.id)
    end

    # M5: a node whose id changed after it started the queue.
    test "in the directory's queue on a node without the directory it waits on its budget", %{
      dir: dir,
      b: b,
      a_id: id,
      qa: qa
    } do
      advertise!(dir, "a@host")

      assert {:snooze, 30} =
               BackupCluster.as_node(b, fn ->
                 perform_job(StepWorker, dump_args(id), queue: qa)
               end)

      assert {:error, :backup_dir_elsewhere} =
               BackupCluster.as_node(b, fn ->
                 perform_job(StepWorker, dump_args(id), queue: qa, meta: %{"snoozed" => 20})
               end)
    end

    test "a per-directory marker sync is moved to its directory's queue", %{
      dir: dir,
      b: b,
      a_id: id,
      qa: qa
    } do
      advertise!(dir, "a@host")
      {:ok, inserted} = Oban.insert(MarkerSyncWorker.new(%{"dir" => id}))

      assert [%{snoozed: 1}] = BackupCluster.drain_as(b, ["default"])
      assert %{queue: ^qa, attempt: 0, state: "scheduled"} = job(inserted.id)
    end

    test "a marker sync in its directory's queue on a node without it waits, then gives up", %{
      dir: dir,
      b: b,
      a_id: id,
      qa: qa
    } do
      advertise!(dir, "a@host")

      assert {:snooze, 30} =
               BackupCluster.as_node(b, fn ->
                 perform_job(MarkerSyncWorker, %{"dir" => id}, queue: qa)
               end)

      assert {:cancel, :backup_dir_elsewhere} =
               BackupCluster.as_node(b, fn ->
                 perform_job(MarkerSyncWorker, %{"dir" => id},
                   queue: qa,
                   meta: %{"snoozed" => 20}
                 )
               end)
    end

    test "the marker sync fan-out queues into the queues advertised, else into default", %{
      dir: dir,
      b: b,
      a_id: a_id,
      qa: qa
    } do
      advertise!(dir, "a@host")
      c_id = Ash.UUID.generate()
      beat!("c@host", %{dir_id: c_id})
      put_config(marker_sync_syncer: fn _dir -> :ok end)

      assert :ok = BackupCluster.as_node(b, fn -> perform_job(MarkerSyncWorker, %{}) end)

      queued =
        Repo.all(
          from(j in Oban.Job,
            where: j.worker == "KilnCMS.Backups.MarkerSyncWorker",
            select: {j.args["dir"], j.queue}
          )
        )

      assert Enum.sort(queued) == Enum.sort([{a_id, qa}, {c_id, "default"}])
    end
  end

  # -- inserts -----------------------------------------------------------------

  describe "inserting a chain's steps" do
    @describetag :pg_tools

    test "with the queue advertised, every step after start goes straight to it", %{
      dir: dir,
      qa: qa
    } do
      advertise!(dir, "a@host")
      assert :ok = BackupChain.run()

      [start | steps] = BackupChain.step_jobs()
      assert start.queue == "backup_steps" and start.args["step"] == "start"
      assert steps != []

      for step <- steps do
        assert step.queue == qa, "#{step.args["step"]} was in #{step.queue}"
        assert step.attempt == 1
        assert step.meta["snoozed"] in [nil, 0]
      end
    end

    # M1: B always fetches first; only A runs A's queue.
    test "with another node fetching first, no step snoozes or spends an attempt", %{
      dir: dir,
      b: b,
      qa: qa
    } do
      advertise!(dir, "a@host")
      advertise!(b, "b@host")

      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} = request()
        # The fresh start runs anywhere: here A's, so the chain is A's.
        assert [%{success: 1}] = BackupCluster.drain_as(dir, ["backup_steps"])

        Enum.reduce_while(1..40, nil, fn _, _ ->
          BackupCluster.drain_as(b, ["backup_steps"])
          BackupCluster.drain_as(dir, ["backup_steps", qa])

          case BackupChain.settled(chain) do
            {:error, :unsettled} -> {:cont, nil}
            outcome -> {:halt, assert(outcome == :ok)}
          end
        end)
      end)

      for step <- BackupChain.step_jobs() do
        assert step.attempt == 1
        assert step.meta["snoozed"] in [nil, 0]
        assert step.errors == []
      end
    end

    test "with directory queues off every step is in backup_steps", %{dir: dir} do
      advertise!(dir, "a@host")
      put_config(dir_queues?: false)
      assert :ok = BackupChain.run()

      assert Enum.all?(BackupChain.step_jobs(), &(&1.queue == "backup_steps"))
    end

    test "a step taken back from a stopped node is requeued in backup_steps", %{
      dir: dir,
      qa: qa
    } do
      advertise!(dir, "a@host")
      {:ok, %{status: :started}} = request()
      job = step_until("dump")
      assert job.queue == qa

      {:ok, _lease} = Chain.begin_step(job)

      {1, _} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [
            state: "executing",
            attempt: 1,
            attempted_at: DateTime.add(DateTime.utc_now(), -600, :second),
            attempted_by: ["gone@node", Ash.UUID.generate()]
          ]
        )

      assert {:ok, {:requeued, %{job_id: new_id}}} = Chain.reclaim_stale()
      assert %{queue: "backup_steps", state: "available"} = job(new_id)
    end

    test "Cancel finds the chain's step in its directory's queue", %{dir: dir, qa: qa} do
      advertise!(dir, "a@host")
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("dump")
      assert job.queue == qa
      {:ok, other} = Oban.insert(StepWorker.new(dump_args(Ash.UUID.generate())))

      {:ok, :ok} = Repo.transaction(fn -> Chain.cancel_chain_jobs(chain) end)

      assert %{state: "cancelled"} = job(job.id)
      assert %{state: "available"} = job(other.id)
    end
  end

  # -- the stranded sweep ----------------------------------------------------

  describe "a backup step left in a directory queue (B2)" do
    @describetag :pg_tools

    setup %{qa: qa} do
      {:ok, %{status: :started, chain: chain}} = request()
      job = step_until("dump")
      %{chain: chain, holder: job, stamp: lock().stamp, q: qa}
    end

    test "(i) a node reports the directory but none runs its queue: back to backup_steps " <>
           "after 5 minutes",
         %{dir: dir, holder: holder, q: q, chain: chain} do
      attach([[:kiln_cms, :backups, :lock, :stranded]])
      # The first tick's beat reports the directory and advertises nothing.
      BackupCluster.tick_as(dir, "a@host")

      park!(holder.id, q, 299)
      assert {:ok, :none} = Chain.sweep_stranded()
      assert %{queue: ^q} = job(holder.id)

      park!(holder.id, q, 301)
      assert {:ok, {:moved_back, _}} = Chain.sweep_stranded()
      assert %{queue: "backup_steps", state: "available"} = job(holder.id)
      assert %{chain_id: ^chain, step_job_id: id} = lock()
      assert id == holder.id
      assert_received {:telemetry, _, %{outcome: :moved_back, queue: ^q}}

      # Not routable, so a node without the directory snoozes it there.
      refute DirQueues.routable?(DirQueues.dir_id(q))
    end

    test "(ii) no node reports the directory for 30 minutes: interrupted, the waiter promoted", %{
      holder: holder,
      q: q,
      chain: chain,
      stamp: stamp,
      a_id: a_id
    } do
      attach([[:kiln_cms, :backups, :lock, :stranded]])
      {:ok, %{status: :queued}} = request(trigger: "schedule")

      park!(holder.id, q, 1_799)
      assert {:ok, :none} = Chain.sweep_stranded()

      park!(holder.id, q, 1_801)

      log =
        capture_log([level: :error], fn ->
          assert {:ok, {:interrupted, %{chain: ^chain, promoted: promoted}}} =
                   Chain.sweep_stranded()

          assert %{chain: ^promoted, trigger: "schedule"} = Backups.in_flight()
        end)

      assert log =~ "waited 30 minutes for a server with its backup directory (id #{a_id})"
      assert %{state: "cancelled"} = job(holder.id)
      assert_received {:telemetry, _, %{outcome: :interrupted}}

      assert %{status: :failed, error: error} =
               Backups.get_run_by_stamp!(stamp, actor: Backups.system())

      assert error ==
               "Interrupted: no server with its backup directory (id #{a_id}) picked up the " <>
                 "dump step for 30 minutes"
    end

    # A Lifeline-rescued job keeps its old `scheduled_at`: hours "waiting".
    test "(iii) a queue a live node advertises is left alone, however long the job waited", %{
      dir: dir,
      holder: holder,
      q: q
    } do
      advertise!(dir, "a@host")
      park!(holder.id, q, 3 * 3600)

      assert {:ok, :none} = Chain.sweep_stranded()
      assert %{queue: ^q, state: "available"} = job(holder.id)
    end

    test "Lifeline-shaped on a directory a node reports but doesn't advertise: moved back, " <>
           "never interrupted",
         %{dir: dir, holder: holder, q: q} do
      BackupCluster.tick_as(dir, "a@host")
      park!(holder.id, q, 3 * 3600)

      assert {:ok, {:moved_back, _}} = Chain.sweep_stranded()
      assert %{queue: "backup_steps", state: "available"} = job(holder.id)
    end

    test "a start in a directory queue no node reports goes back to backup_steps, still held", %{
      q: q
    } do
      # A promoted start, to stand for a resume's start parked in its queue.
      {:ok, %{status: :queued}} = request(trigger: "schedule")
      {:ok, _promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      %{step: :start, step_job_id: start_id} = lock()

      park!(start_id, q, 1_801)
      assert {:ok, {:returned, _}} = Chain.sweep_stranded()
      assert %{queue: "backup_steps", state: "available"} = job(start_id)
      assert %{step: :start, step_job_id: ^start_id} = lock()
    end

    test "a job of a chain that moved on is canceled", %{holder: holder, q: q} do
      {:ok, stray} = Oban.insert(StepWorker.new(dump_args(DirQueues.dir_id(q))))
      park!(stray.id, q, 1_801)
      park!(holder.id, q, 60)

      assert {:ok, :none} = Chain.sweep_stranded()
      assert %{state: "cancelled"} = job(stray.id)
      assert %{queue: ^q, state: "available"} = job(holder.id)
    end

    test "beats that can't be read leave everything, with a warning", %{holder: holder, q: q} do
      park!(holder.id, q, 3 * 3600)
      put_config(live_beats_reader: fn _within_s -> {:error, :connection_refused} end)

      log = capture_log([level: :warning], fn -> assert {:ok, :none} = Chain.sweep_stranded() end)

      assert log =~ "Backup stranded-step sweep skipped: couldn't read the node heartbeats"
      assert %{queue: ^q, state: "available"} = job(holder.id)
    end

    test "the lock's sweep runs it third", %{holder: holder, q: q} do
      park!(holder.id, q, 1_801)

      assert {:ok, %{reclaimed: :none, reaped: :none, stranded: %{outcome: :interrupted}}} =
               Backups.reclaim_stale_backups(actor: Backups.system())
    end

    test "a resume's start parked in its directory's queue is waiting for the files server", %{
      q: q
    } do
      {:ok, _} = Chain.with_lock(&Chain.release_in_txn/1)
      {:ok, %{status: :started}} = request()
      %{step_job_id: start_id} = lock()
      Repo.query!("UPDATE backup_locks SET resume_stamp = '20260101-000000'")
      park!(start_id, q, 0)

      assert %{waiting_for: :files_server} = Backups.in_flight(details: true)
    end
  end

  describe "a marker sync left in a directory queue (B3)" do
    defp sync_job!(dir_id, queue, waited_s) do
      {:ok, job} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      park!(job.id, queue, waited_s)
      job
    end

    test "canceled after 5 minutes when no node advertises the queue a live node reports", %{
      dir: dir,
      a_id: id,
      qa: qa
    } do
      BackupCluster.tick_as(dir, "a@host")
      early = sync_job!(id, qa, 299)
      assert MarkerSyncWorker.sweep_stranded() == 0
      assert %{state: "available"} = job(early.id)

      park!(early.id, qa, 301)

      log =
        capture_log([level: :warning], fn -> assert MarkerSyncWorker.sweep_stranded() == 1 end)

      assert log =~ "Backup last-good marker sync for backup directory #{id} gave up"
      assert %{state: "cancelled"} = job(early.id)
    end

    test "canceled after 30 minutes when no node reports the directory", %{a_id: id, qa: qa} do
      job = sync_job!(id, qa, 1_799)
      assert MarkerSyncWorker.sweep_stranded() == 0

      park!(job.id, qa, 1_801)
      assert MarkerSyncWorker.sweep_stranded() == 1
      assert %{state: "cancelled"} = job(job.id)
    end

    test "each heartbeat tick sweeps them", %{dir: dir} do
      gone = Ash.UUID.generate()
      job = sync_job!(gone, DirQueues.name(gone), 1_801)

      BackupCluster.tick_as(dir, "a@host")
      assert %{state: "cancelled"} = job(job.id)
    end

    test "left alone while a live node advertises the queue", %{dir: dir, a_id: id, qa: qa} do
      advertise!(dir, "a@host")
      job = sync_job!(id, qa, 3 * 3600)

      assert MarkerSyncWorker.sweep_stranded() == 0
      assert %{state: "available"} = job(job.id)
    end
  end
end
