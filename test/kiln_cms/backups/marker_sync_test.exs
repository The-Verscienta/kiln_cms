defmodule KilnCMS.Backups.MarkerSyncTest do
  @moduledoc """
  The last-good marker for cron-only deployments (#2554): `MarkerSyncWorker`
  and `Chain.sync_last_good/2`. A cron-made backup gets its `.good` marker
  with nobody running a command; the sync writes nothing while a chain holds
  the lock, reaches every host's backup directory through the ids the
  heartbeats create and report (#2789), and fails closed. That a sync and a request are serialized needs two real
  connections: it is in `ChainRaceTest`.

  `async: false`: points the VM-wide backup directory at temporary ones (one
  per simulated host, `KilnCMS.Test.BackupCluster`) and changes the
  `:backup_marker_sync_cron` key.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupCluster
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, DirId, Heartbeat, MarkerSyncWorker}
  alias KilnCMS.Test.BackupSchedules

  @moduletag :capture_log

  # A backup made by `backup.sh` (a few months old, so a plausible stamp), and
  # an older one whose marker the sync must move off.
  @cron "20260801-031700"
  @old "20260701-031700"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_mks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(original, dir: dir))

    on_exit(fn ->
      File.chmod(Path.join(dir, ".work"), 0o700)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  defp old_marker!(dir), do: File.write!(Path.join([dir, "db", Artifact.good_name(@old)]), "")

  defp held_lock! do
    {:ok, _row} =
      Chain.with_lock(fn row ->
        {row, _notifications} =
          Backups.hold_backup_lock!(
            row,
            %{chain_id: Ash.UUID.generate(), trigger: "manual", step: :start},
            actor: Backups.system(),
            return_notifications?: true
          )

        {:ok, row}
      end)
  end

  # What Oban does to a job it starts: the next insert sees it as running.
  defp executing!(%Oban.Job{id: id}) do
    {1, _} =
      KilnCMS.Repo.update_all(from(j in Oban.Job, where: j.id == ^id),
        set: [state: "executing", attempted_at: DateTime.utc_now()]
      )

    :ok
  end

  # Every file of `stamp` in `db/` and `media/`, made `days` days old.
  defp age!(dir, stamp, days) do
    at = System.os_time(:second) - days * 86_400

    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(dir, sub)),
        String.contains?(name, stamp),
        do: File.touch!(Path.join([dir, sub, name]), at)

    :ok
  end

  # The `.hold` markers in `dir`, as `"db/<name>"`, sorted.
  defp holds(dir) do
    for sub <- ["db", "media"],
        name <- Enum.sort(File.ls!(Path.join(dir, sub))),
        String.ends_with?(name, ".hold"),
        do: "#{sub}/#{name}"
  end

  defp beat!(dir_id) do
    Backups.beat_node!(
      %{
        node: "node-#{System.unique_integer([:positive])}",
        boot_id: Ash.UUID.generate(),
        dir_id: dir_id
      },
      actor: Backups.system()
    )
  end

  defp attach(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  describe "a cron-only deployment" do
    test "gets its markers from one run of the job, and no directory id", %{dir: dir} do
      cron_backup!(dir, @cron)
      old_marker!(dir)
      ref = attach([[:kiln_cms, :backups, :last_good, :synced]])

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]

      assert_received {[:kiln_cms, :backups, :last_good, :synced], ^ref, %{count: 1},
                       %{db: @cron, media: @cron}}

      # Imported from the manifest, so the history shows it too.
      assert %{origin: :imported, status: :succeeded} =
               Backups.get_run_by_stamp!(@cron, actor: Backups.system())

      refute File.exists?(DirId.path(dir))
    end

    test "gets the hold markers a schedule's keep count asks for (#2219)", %{dir: dir} do
      cron_backup!(dir, @cron)
      stale = Path.join([dir, "db", Artifact.hold_name(@old)])
      File.write!(stale, "")
      KilnCMS.Test.BackupSchedules.schedule!(%{keep_count: 1})
      ref = attach([[:kiln_cms, :backups, :last_good, :synced]])

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert File.exists?(Path.join([dir, "db", Artifact.hold_name(@cron)]))
      refute File.exists?(stale)
      # The schedule backs up the database only.
      refute File.exists?(Path.join([dir, "media", Artifact.hold_name(@cron)]))

      assert_received {[:kiln_cms, :backups, :last_good, :synced], ^ref, %{count: 1},
                       %{db: @cron, held: 1}}
    end

    test "while a chain holds the lock no hold moves either (#2219)", %{dir: dir} do
      cron_backup!(dir, @cron)
      stale = Path.join([dir, "db", Artifact.hold_name(@old)])
      File.write!(stale, "")
      KilnCMS.Test.BackupSchedules.schedule!(%{keep_count: 1})
      held_lock!()

      assert :busy = Chain.sync_last_good(dir)
      assert File.exists?(stale)
      refute File.exists?(Path.join([dir, "db", Artifact.hold_name(@cron)]))
    end

    test "BACKUP_ENABLED=false (the in-app path off) does not stop it", %{dir: dir} do
      config = Application.get_env(:kiln_cms, KilnCMS.Backups)
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(config, :enabled, false))
      cron_backup!(dir, @cron)

      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
    end

    test "no backup directory on this node: nothing happens, and nothing is logged", %{dir: dir} do
      File.rm_rf!(dir)

      log =
        capture_log([level: :warning], fn -> assert :ok = perform_job(MarkerSyncWorker, %{}) end)

      assert log == ""
      refute File.exists?(dir)
    end
  end

  describe "the backup lock" do
    test "while a chain holds it the sync writes nothing and says :busy", %{dir: dir} do
      cron_backup!(dir, @cron)
      old_marker!(dir)
      held_lock!()

      assert :busy = Chain.sync_last_good(dir)
      assert goods(dir) == ["db/kiln-#{@old}.good"]

      # The job is not a failure: the chain syncs the markers when it ends.
      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert goods(dir) == ["db/kiln-#{@old}.good"]
    end
  end

  describe "fails closed" do
    test "an import that fails writes and removes no marker", %{dir: dir} do
      cron_backup!(dir, @cron)
      old_marker!(dir)
      ref = attach([[:kiln_cms, :backups, :last_good, :failed]])

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:import, _}} =
                   Backups.with_actor(nil, fn -> Chain.sync_last_good(dir) end)
        end)

      assert log =~ "Backup last-good marker not updated"
      assert goods(dir) == ["db/kiln-#{@old}.good"]

      assert_received {[:kiln_cms, :backups, :last_good, :failed], ^ref, %{count: 1},
                       %{reason: {:import, _}}}
    end

    test "a directory it can't read under the lock writes nothing, reported once",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      old_marker!(dir)
      work = Path.join(dir, ".work")
      File.mkdir_p!(work)
      File.chmod!(work, 0o000)
      ref = attach([[:kiln_cms, :backups, :last_good, :failed]])

      assert {:error, {:ls, ".work", :eacces}} = Chain.sync_last_good(dir)
      assert goods(dir) == ["db/kiln-#{@old}.good"]

      assert_received {[:kiln_cms, :backups, :last_good, :failed], ^ref, _, _}
      refute_received {[:kiln_cms, :backups, :last_good, :failed], ^ref, _, _}
    end

    test "a job that can't read the node heartbeats fails and writes nothing", %{dir: dir} do
      cron_backup!(dir, @cron)

      assert {:error, {:node_beats, _}} =
               Backups.with_actor(nil, fn -> perform_job(MarkerSyncWorker, %{}) end)

      assert goods(dir) == []
    end
  end

  describe "which node" do
    test "a job for another backup directory snoozes, then gives up", %{dir: dir} do
      cron_backup!(dir, @cron)
      {:ok, _local} = DirId.local(dir)
      elsewhere = Ash.UUID.generate()

      assert {:snooze, 30} = perform_job(MarkerSyncWorker, %{"dir" => elsewhere})

      assert {:cancel, :backup_dir_elsewhere} =
               perform_job(MarkerSyncWorker, %{"dir" => elsewhere}, meta: %{"snoozed" => 20})

      assert goods(dir) == []
    end

    test "a job for this node's backup directory syncs it", %{dir: dir} do
      cron_backup!(dir, @cron)
      {:ok, local} = DirId.local(dir)

      assert :ok = perform_job(MarkerSyncWorker, %{"dir" => local})
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
    end

    test "with ids reported, the cron job syncs its own directory in place and queues one job " <>
           "per other directory",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      {:ok, local} = DirId.local(dir)
      other = Ash.UUID.generate()
      beat!(local)
      beat!(other)
      beat!(nil)

      assert :ok = perform_job(MarkerSyncWorker, %{})

      # No job for its own id (#2789): the node that fetched the cron job
      # covers its own directory every slot, without a snooze.
      assert [%{args: %{"dir" => ^other}}] = all_enqueued(worker: MarkerSyncWorker)
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
    end

    test "with ids reported, a node whose own directory has none syncs it there and then",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      other = Ash.UUID.generate()
      beat!(other)

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert [%{args: %{"dir" => ^other}}] = all_enqueued(worker: MarkerSyncWorker)
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
      refute File.exists?(DirId.path(dir))
    end

    test "one waiting job per directory: the next slot does not stack another behind it" do
      dir_id = Ash.UUID.generate()

      assert {:ok, %{conflict?: false}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      assert {:ok, %{conflict?: false}} = Oban.insert(MarkerSyncWorker.new(%{}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{}))
    end

    test "a snoozing job (scheduled) still counts as waiting" do
      dir_id = Ash.UUID.generate()

      assert {:ok, %{state: "scheduled"}} =
               Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}, schedule_in: 30))

      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
    end

    test "a running job does not (#2932): one more queues behind it, and only one" do
      dir_id = Ash.UUID.generate()
      {:ok, running} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      executing!(running)

      assert {:ok, %{conflict?: false}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
    end

    test "the fan-out queues a directory's job while that directory's last one runs (#2932)" do
      other = Ash.UUID.generate()
      beat!(other)
      {:ok, running} = Oban.insert(MarkerSyncWorker.new(%{"dir" => other}))
      executing!(running)

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert [%{args: %{"dir" => ^other}, id: id}] = all_enqueued(worker: MarkerSyncWorker)
      refute id == running.id
    end

    test "the fan-out queues nothing while that directory's job snoozes" do
      other = Ash.UUID.generate()
      beat!(other)
      {:ok, snoozing} = Oban.insert(MarkerSyncWorker.new(%{"dir" => other}, schedule_in: 30))

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert [%{id: id}] = all_enqueued(worker: MarkerSyncWorker)
      assert id == snoozing.id
    end
  end

  describe "a schedule change while a sync runs (#2932)" do
    setup %{dir: dir} do
      # Two cron backups: one a day old, one 20 days old, past
      # BACKUP_KEEP_DAYS (14) but inside the 30 days the change asks for.
      cron_backup!(dir, @cron)
      cron_backup!(dir, @old)
      age!(dir, @cron, 1)
      age!(dir, @old, 20)

      # The create queues the sync that is about to run.
      schedule = BackupSchedules.schedule!(%{keep_days: 7})
      assert [job] = all_enqueued(worker: MarkerSyncWorker)
      %{schedule: schedule, job: job}
    end

    test "queues a second sync, which writes the holds the change asks for",
         %{dir: dir, schedule: schedule, job: job} do
      # The running sync read the schedules before the change: keep_days 7
      # lowers nothing below the 14-day floor, so it holds nothing.
      assert :ok = perform_job(MarkerSyncWorker, job.args)
      assert holds(dir) == []
      executing!(job)

      assert {:ok, _} =
               Backups.update_backup_schedule(schedule, %{keep_days: 30},
                 actor: BackupSchedules.platform_admin()
               )

      assert [%{id: id, args: %{}}] = all_enqueued(worker: MarkerSyncWorker)
      refute id == job.id

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)

      # The schedule backs up the database only, so media keeps the 14-day
      # floor and needs no hold.
      assert holds(dir) == ["db/kiln-#{@old}.hold", "db/kiln-#{@cron}.hold"]
    end

    test "a sync still waiting is not doubled: it reads the change when it runs",
         %{dir: dir, schedule: schedule, job: job} do
      assert {:ok, _} =
               Backups.update_backup_schedule(schedule, %{keep_days: 30},
                 actor: BackupSchedules.platform_admin()
               )

      assert [%{id: id}] = all_enqueued(worker: MarkerSyncWorker)
      assert id == job.id

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
      assert holds(dir) == ["db/kiln-#{@old}.hold", "db/kiln-#{@cron}.hold"]
    end
  end

  # #2985: a change made while an in-app backup holds the lock reaches the
  # holds once the chain lets go, however the backup ended.
  describe "a schedule change while an in-app backup holds the lock (#2985)" do
    setup %{dir: dir} do
      # As in the #2932 setup: keep_days 30 holds both cron backups' db.
      cron_backup!(dir, @cron)
      cron_backup!(dir, @old)
      age!(dir, @cron, 1)
      age!(dir, @old, 20)

      schedule = BackupSchedules.schedule!(%{keep_days: 7})
      assert [job] = all_enqueued(worker: MarkerSyncWorker)
      assert job.args == %{}
      assert job.meta == %{"schedule_change" => true}
      %{schedule: schedule, job: job}
    end

    # What a failed chain does: free the lock, with no marker sync of its own
    # (only a successful finish step syncs).
    defp chain_fails_and_releases! do
      {:ok, _promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      :ok
    end

    test "its sync snoozes on :busy without using its attempt, then writes the new holds " <>
           "once the chain releases, though the backup failed",
         %{dir: dir, schedule: schedule, job: job} do
      held_lock!()

      assert {:ok, _} =
               Backups.update_backup_schedule(schedule, %{keep_days: 30},
                 actor: BackupSchedules.platform_admin()
               )

      # Still the one waiting job: it reads the change when it runs.
      assert [%{id: id}] = all_enqueued(worker: MarkerSyncWorker)
      assert id == job.id

      assert %{snoozed: 1, success: 0, failure: 0} =
               Oban.drain_queue(queue: :default, with_scheduled: false)

      assert holds(dir) == []

      assert %{
               state: "scheduled",
               attempt: 0,
               max_attempts: 1,
               meta: %{"snoozed" => 1, "schedule_change" => true}
             } =
               KilnCMS.Repo.get!(Oban.Job, job.id)

      # Still busy: it snoozes again, for as long as the chain holds the lock.
      assert {:snooze, 120} = perform_job(MarkerSyncWorker, job.args, meta: job.meta)

      chain_fails_and_releases!()

      assert %{success: 1, failure: 0, snoozed: 0} =
               Oban.drain_queue(queue: :default, with_scheduled: true)

      assert holds(dir) == ["db/kiln-#{@old}.hold", "db/kiln-#{@cron}.hold"]
    end

    test "while it snoozes, a cron slot or another change queues nothing more", %{job: job} do
      {1, _} =
        KilnCMS.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [state: "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 60)]
        )

      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.schedule_change_job())
      assert [%{id: id}] = all_enqueued(worker: MarkerSyncWorker)
      assert id == job.id
    end

    test "it queues the other directories' jobs only once the lock is free", %{job: job} do
      other = Ash.UUID.generate()
      beat!(other)
      held_lock!()

      assert {:snooze, 120} = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
      refute Enum.any?(all_enqueued(worker: MarkerSyncWorker), &(&1.args["dir"] == other))

      chain_fails_and_releases!()

      assert :ok = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
      assert Enum.any?(all_enqueued(worker: MarkerSyncWorker), &(&1.args["dir"] == other))
    end

    test "the cron slot's job and a per-directory job still treat :busy as done", %{dir: dir} do
      {:ok, local} = DirId.local(dir)
      held_lock!()

      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert :ok = perform_job(MarkerSyncWorker, %{"dir" => local})
      assert holds(dir) == []
    end
  end

  # The review's follow-ups to #2985: every way the flagged job could still
  # drop the change while a chain holds the lock.
  describe "a schedule change's job: what it waits on (#2985)" do
    @flag %{"schedule_change" => true}

    setup %{dir: dir} do
      cron_backup!(dir, @cron)
      cron_backup!(dir, @old)
      age!(dir, @cron, 1)
      age!(dir, @old, 20)
      BackupSchedules.schedule!(%{keep_days: 30})
      assert [job] = all_enqueued(worker: MarkerSyncWorker)
      %{job: job}
    end

    defp release_lock! do
      {:ok, _promoted} = Chain.with_lock(&Chain.release_in_txn/1)
      :ok
    end

    defp dir_jobs(dir_id),
      do: for(j <- all_enqueued(worker: MarkerSyncWorker), j.args["dir"] == dir_id, do: j)

    test "its own directory not answering: it snoozes and queues no other directory's job",
         %{job: job} do
      other = Ash.UUID.generate()
      beat!(other)
      put_backups_env(marker_sync_dir_reader: fn _dir -> {:error, :backup_dir_unresponsive} end)

      assert {:snooze, 120} = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
      assert dir_jobs(other) == []
    end

    test "the directory jobs it queues carry the flag", %{job: job} do
      other = Ash.UUID.generate()
      beat!(other)

      assert :ok = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
      assert [%{meta: @flag}] = dir_jobs(other)
    end

    test "it flags a directory's unflagged job that is already waiting or snoozing", %{job: job} do
      other = Ash.UUID.generate()
      beat!(other)

      {:ok, snoozing} =
        Oban.insert(MarkerSyncWorker.new(%{"dir" => other}, schedule_in: 30))

      assert :ok = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
      assert [%{id: id, meta: @flag}] = dir_jobs(other)
      assert id == snoozing.id
    end

    test "a flagged directory job snoozes on :busy and writes the holds once the chain lets go",
         %{dir: dir} do
      {:ok, local} = DirId.local(dir)
      held_lock!()

      assert {:snooze, 120} = perform_job(MarkerSyncWorker, %{"dir" => local}, meta: @flag)
      assert holds(dir) == []

      release_lock!()
      assert :ok = perform_job(MarkerSyncWorker, %{"dir" => local}, meta: @flag)
      assert holds(dir) == ["db/kiln-#{@old}.hold", "db/kiln-#{@cron}.hold"]
    end

    test "a chain that starts before another host's job runs: that job snoozes, not drops",
         %{job: job} do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")
      tick_as(a, "a@host")
      tick_as(b, "b@host")
      {:ok, id_b} = DirId.current(b)

      assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, job.args, meta: job.meta) end)
      assert [%{meta: @flag} = routed] = dir_jobs(id_b)

      held_lock!()

      assert {:snooze, 120} =
               as_node(b, fn -> perform_job(MarkerSyncWorker, routed.args, meta: routed.meta) end)

      assert goods(b) == ["db/kiln-#{@old}.good"]

      release_lock!()

      assert :ok =
               as_node(b, fn -> perform_job(MarkerSyncWorker, routed.args, meta: routed.meta) end)

      assert goods(b) == synced("20260801-041700")
    end

    test "on a node with no backup directory it waits while a chain holds the lock",
         %{dir: dir, job: job} do
      File.rm_rf!(dir)
      held_lock!()

      assert {:snooze, 120} = perform_job(MarkerSyncWorker, job.args, meta: job.meta)

      # Unflagged, the same node has nothing to do.
      assert :ok = perform_job(MarkerSyncWorker, %{})

      release_lock!()
      assert :ok = perform_job(MarkerSyncWorker, job.args, meta: job.meta)
    end

    test "it gives up after three hours of waiting, with a warning", %{job: job} do
      held_lock!()
      # As Oban hands a fetched job to the worker.
      stored = %{
        KilnCMS.Repo.get!(Oban.Job, job.id)
        | attempt: 1,
          attempted_at: DateTime.utc_now()
      }

      waited = %{stored | inserted_at: DateTime.add(DateTime.utc_now(), -3 * 3600 - 1)}

      log =
        capture_log([level: :warning], fn ->
          assert {:cancel, :backup_lock_held} = perform_job(waited)
        end)

      assert log =~ "gave up: an in-app backup held the backup lock for 3 hours"

      fresh = %{stored | inserted_at: DateTime.add(DateTime.utc_now(), -2 * 3600)}
      assert {:snooze, 120} = perform_job(fresh)
    end

    test "flagged_waiting?/0: only a flagged job without a directory, still waiting",
         %{job: job} do
      assert MarkerSyncWorker.flagged_waiting?()

      executing!(job)
      refute MarkerSyncWorker.flagged_waiting?()

      Oban.insert!(MarkerSyncWorker.new(%{"dir" => Ash.UUID.generate()}, meta: @flag))
      refute MarkerSyncWorker.flagged_waiting?()

      Oban.insert!(MarkerSyncWorker.new(%{}))
      refute MarkerSyncWorker.flagged_waiting?()
    end
  end

  describe "a cron slot's job waiting when a schedule changes (#2985)" do
    test "becomes the schedule change's job, so :busy doesn't drop the change" do
      assert {:ok, %{conflict?: false, id: id}} = Oban.insert(MarkerSyncWorker.new(%{}))

      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.schedule_change_job())

      assert %{meta: %{"schedule_change" => true}} = KilnCMS.Repo.get!(Oban.Job, id)
      assert [_one] = all_enqueued(worker: MarkerSyncWorker)
    end
  end

  describe "the schedule" do
    defp crontab do
      plugins = Keyword.fetch!(KilnCMS.Application.oban_config(), :plugins)
      {Oban.Plugins.Cron, opts} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
      opts[:crontab]
    end

    defp put_cron(value) do
      original = Application.fetch_env(:kiln_cms, :backup_marker_sync_cron)
      Application.put_env(:kiln_cms, :backup_marker_sync_cron, value)

      on_exit(fn ->
        case original do
          {:ok, old} -> Application.put_env(:kiln_cms, :backup_marker_sync_cron, old)
          :error -> Application.delete_env(:kiln_cms, :backup_marker_sync_cron)
        end
      end)
    end

    test "every 15 minutes by default, on its own entry" do
      assert {"*/15 * * * *", MarkerSyncWorker} = List.keyfind(crontab(), MarkerSyncWorker, 1)
      assert {:ok, _} = Oban.Cron.Expression.parse("*/15 * * * *")
    end

    test "KILN_BACKUP_MARKER_SYNC_CRON=false takes it off the crontab" do
      put_cron("false")
      refute List.keymember?(crontab(), MarkerSyncWorker, 1)
    end

    test "an override replaces the default" do
      put_cron("5 * * * *")
      assert {"5 * * * *", MarkerSyncWorker} = List.keyfind(crontab(), MarkerSyncWorker, 1)
    end

    test "one attempt on the default queue: the next slot is the retry" do
      opts = MarkerSyncWorker.__opts__()
      assert opts[:queue] == :default
      assert opts[:max_attempts] == 1
    end
  end

  describe "per-host directories (#2789)" do
    # A host with its own backup directory, holding one cron backup (stamp
    # `stamp`) and the old marker the sync must move off.
    defp host!(name, stamp) do
      dir = Path.join(System.tmp_dir!(), "kiln_mks_#{name}_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      cron_backup!(dir, stamp)
      old_marker!(dir)
      dir
    end

    defp synced(stamp), do: ["db/kiln-#{stamp}.good", "media/kiln-#{stamp}.good"]

    defp routed_jobs do
      for job <- all_enqueued(worker: MarkerSyncWorker), Map.has_key?(job.args, "dir"), do: job
    end

    # One slot: the cron job is fetched by the node of `fetcher`, then each
    # routed job is fetched by the nodes in `order`, one fetch each, until one
    # runs it (a snooze is the next fetch). The job is then done.
    defp slot!(fetcher, order) do
      assert :ok = as_node(fetcher, fn -> perform_job(MarkerSyncWorker, %{}) end)
      Enum.each(routed_jobs(), &fetch_routed!(&1, order))
    end

    defp fetch_routed!(job, order) do
      _result = Enum.reduce_while(order, 0, &fetch_once(job, &1, &2))

      KilnCMS.Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "completed"]
      )
    end

    defp fetch_once(job, dir, snoozed) do
      result =
        as_node(dir, fn ->
          perform_job(MarkerSyncWorker, job.args, meta: %{"snoozed" => snoozed})
        end)

      if result == {:snooze, 30}, do: {:cont, snoozed + 1}, else: {:halt, result}
    end

    test "two hosts and no ids: the heartbeats create them, and both get a marker in slot 1" do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")

      tick_as(a, "a@host")
      tick_as(b, "b@host")

      assert {:ok, id_a} = DirId.current(a)
      assert {:ok, id_b} = DirId.current(b)
      assert id_a != id_b
      assert beat_of("a@host").dir_id == id_a
      assert beat_of("b@host").dir_id == id_b

      # Slot 1, the cron job fetched by A: A synced in place, one job for B.
      assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, %{}) end)
      assert goods(a) == synced("20260801-031700")
      assert [%{args: %{"dir" => ^id_b}} = job] = routed_jobs()

      assert {:snooze, 30} = as_node(a, fn -> perform_job(MarkerSyncWorker, job.args) end)
      assert goods(b) == ["db/kiln-#{@old}.good"]

      assert :ok = as_node(b, fn -> perform_job(MarkerSyncWorker, job.args) end)
      assert goods(b) == synced("20260801-041700")
    end

    test "the cron job always fetched by A: B is still marked every slot" do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")
      tick_as(a, "a@host")
      tick_as(b, "b@host")

      for day <- ["02", "03", "04"] do
        cron_backup!(a, "202608#{day}-031700")
        cron_backup!(b, "202608#{day}-041700")

        # A fetches the cron job and the routed job twice before B gets it.
        slot!(a, [a, a, b])

        assert goods(a) == synced("202608#{day}-031700")
        assert goods(b) == synced("202608#{day}-041700")
      end
    end

    # #2543: the beat's upsert writes a nil id too, so the fan-out stops
    # queueing syncs for a directory that is gone ("no node with that
    # directory" every slot).
    test "a node whose directory lost its id stops reporting it; no job is queued for the old id" do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")

      tick_as(a, "a@host")
      state_b = tick_as(b, "b@host")
      assert {:ok, id_b} = DirId.current(b)
      assert beat_of("b@host").dir_id == id_b

      # B's volume is replaced by an empty one: no backups, no id file.
      for entry <- File.ls!(b), do: File.rm_rf!(Path.join(b, entry))
      tick_as(b, state_b)

      refute File.exists?(DirId.path(b))
      assert beat_of("b@host").dir_id == nil

      assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, %{}) end)
      assert routed_jobs() == []
    end

    # The mutation check: without the heartbeat's ids (the job turned off
    # here, so no tick creates one) the test above fails. B is never reached.
    test "without the heartbeat's ids, a host whose node never fetches the cron job stays " <>
           "unmarked" do
      put_cron("false")
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")
      tick_as(a, "a@host")
      tick_as(b, "b@host")

      for _slot <- 1..3, do: slot!(a, [a, a, b])

      assert goods(a) == synced("20260801-031700")
      assert goods(b) == ["db/kiln-#{@old}.good"]
      refute File.exists?(DirId.path(b))
    end

    test "a shared volume: nodes racing to create the id settle on one, never a malformed " <>
           "one, and the cron job syncs it in place with no routed job" do
      shared = host!("shared", @cron)
      id_file = DirId.path(shared)
      parent = self()

      # Everyone waits for :go, so the creators really race. A reader polls
      # the id while they do: a published id is never empty or partial.
      as_node(shared, fn ->
        reader =
          Task.async(fn ->
            send(parent, :reader_ready)
            read_until_published(id_file, shared)
          end)

        creators =
          for n <- 1..8 do
            Task.async(fn ->
              receive do
                :go -> :ok
              end

              case rem(n, 3) do
                0 -> {:local, DirId.local(shared)}
                1 -> {:ensure, DirId.ensure_existing(shared)}
                2 -> {:tick, Heartbeat.tick(Heartbeat.new_state(node: "shared-#{n}@host"))}
              end
            end)
          end

        assert_receive :reader_ready
        Enum.each(creators, &send(&1.pid, :go))
        results = Task.await_many(creators, 15_000)

        assert {:ok, id} = DirId.current(shared)

        for result <- results do
          case result do
            {:tick, _state} -> :ok
            {_creator, created} -> assert created == {:ok, id}
          end
        end

        assert Task.await(reader, 15_000) == :ok

        for n <- 1..8, rem(n, 3) == 2, do: assert(beat_of("shared-#{n}@host").dir_id == id)

        # No temporary file is left behind.
        assert File.ls!(shared) |> Enum.filter(&String.starts_with?(&1, ".kiln-dir-id")) ==
                 [".kiln-dir-id"]

        assert :ok = perform_job(MarkerSyncWorker, %{})
        assert routed_jobs() == []
        assert goods(shared) == synced(@cron)
      end)
    end

    test "a node down for many slots gets no job, and no give-up, until it beats again" do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")
      tick_as(a, "a@host")
      tick_as(b, "b@host")
      {:ok, id_b} = DirId.current(b)
      backdate_beat!("b@host", 11 * 60)

      log =
        capture_log([level: :warning], fn ->
          for _slot <- 1..3 do
            assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, %{}) end)
            assert routed_jobs() == []
          end
        end)

      refute log =~ "gave up"
      assert goods(a) == synced("20260801-031700")
      assert goods(b) == ["db/kiln-#{@old}.good"]

      # B's node is back: the next slot reaches it.
      tick_as(b, "b@host")
      assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, %{}) end)
      assert [%{args: %{"dir" => ^id_b}} = job] = routed_jobs()
      fetch_routed!(job, [a, b])
      assert goods(b) == synced("20260801-041700")
    end

    # #2478 needs #2789: on a cron-only host the Importer reaches the host's
    # directory only through its routed job, and must, before prune removes a
    # killed run's marker.
    test "a cron-only host's killed run is recorded as interrupted through its routed job" do
      a = host!("a", "20260801-031700")
      b = host!("b", "20260801-041700")
      killed = "20260802-041700"
      killed_run!(b, killed, 4 * 60)
      tick_as(a, "a@host")
      tick_as(b, "b@host")

      assert :ok = as_node(a, fn -> perform_job(MarkerSyncWorker, %{}) end)
      assert {:ok, nil} = Backups.get_run_by_stamp(killed, actor: Backups.system())

      assert [job] = routed_jobs()
      fetch_routed!(job, [a, b])

      assert %{status: :failed, error: "Interrupted: " <> _, components: [:db, :media]} =
               Backups.get_run_by_stamp!(killed, actor: Backups.system())

      # The last good backup is still the finished one before it.
      assert goods(b) == synced("20260801-041700")
    end
  end

  # :ok once the id file holds an id, after reading it every few hundred
  # microseconds while it is created; a malformed read fails the test.
  defp read_until_published(
         id_file,
         dir,
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    cond do
      not File.exists?(id_file) and System.monotonic_time(:millisecond) < deadline ->
        read_until_published(id_file, dir, deadline)

      not File.exists?(id_file) ->
        {:error, :timeout}

      true ->
        # A few more reads once it is there, then done.
        results = for _ <- 1..50, do: DirId.current(dir)
        if Enum.all?(results, &match?({:ok, _}, &1)), do: :ok, else: {:error, results}
    end
  end

  describe "the heartbeat's backup-directory id (#2789)" do
    defp tick_log(dir, state) do
      {state, log} = with_log([level: :warning], fn -> tick_as(dir, state) end)
      {state, log}
    end

    test "a directory that holds backups gets an id, which the beat reports", %{dir: dir} do
      refute File.exists?(DirId.path(dir))

      {_state, log} = tick_log(dir, "this@node")

      assert {:ok, id} = DirId.current(dir)
      assert beat_of("this@node").dir_id == id
      assert log == ""
      assert %File.Stat{mode: mode} = File.stat!(DirId.path(dir))
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "a directory with only db/, or only media/, holds backups", %{dir: dir} do
      File.rm_rf!(Path.join(dir, "media"))
      tick_as(dir, "this@node")
      assert {:ok, _} = DirId.current(dir)

      other = Path.join(System.tmp_dir!(), "kiln_mks_m_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(other) end)
      File.mkdir_p!(Path.join(other, "media"))
      tick_as(other, "other@node")
      assert {:ok, _} = DirId.current(other)
    end

    test "an empty directory (the image's mountpoint, or a failed mount) gets no id", %{dir: dir} do
      File.rm_rf!(Path.join(dir, "db"))
      File.rm_rf!(Path.join(dir, "media"))

      {_state, log} = tick_log(dir, "this@node")

      refute File.exists?(DirId.path(dir))
      assert File.ls!(dir) == []
      assert beat_of("this@node").dir_id == nil
      assert log == ""
    end

    test "no backup directory: none is created, the beat reports no id, nothing is logged",
         %{dir: dir} do
      File.rm_rf!(dir)

      {_state, log} = tick_log(dir, "this@node")

      refute File.exists?(dir)
      assert beat_of("this@node").dir_id == nil
      assert log == ""
    end

    test "with the marker sync off, no id is created and the beat reports none", %{dir: dir} do
      put_cron("false")
      refute MarkerSyncWorker.enabled?()

      tick_as(dir, "this@node")

      refute File.exists?(DirId.path(dir))
      assert beat_of("this@node").dir_id == nil
    end

    test "with the marker sync off, an in-app backup's id is still reported", %{dir: dir} do
      put_cron("false")
      {:ok, id} = DirId.local(dir)

      tick_as(dir, "this@node")
      assert beat_of("this@node").dir_id == id
    end

    test "a hybrid host: the in-app backup's id is left as it is", %{dir: dir} do
      {:ok, id} = DirId.local(dir)
      before = File.stat!(DirId.path(dir), time: :posix)

      tick_as(dir, "this@node")

      assert DirId.current(dir) == {:ok, id}
      assert File.stat!(DirId.path(dir), time: :posix) == before
      assert beat_of("this@node").dir_id == id
    end

    test "a malformed id file is not overwritten: reported as none, warned about once",
         %{dir: dir} do
      File.write!(DirId.path(dir), "not an id\n")

      {state, first} = tick_log(dir, "this@node")
      {_state, second} = tick_log(dir, state)

      assert File.read!(DirId.path(dir)) == "not an id\n"
      assert beat_of("this@node").dir_id == nil
      assert first =~ "no id for the backup directory"
      assert first =~ ":malformed_dir_id"
      assert second == ""
    end

    test "a directory the app can't write: the beat goes out with no id, one warning per boot, " <>
           "and the cron job still syncs it in place",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      {state, first} = tick_log(dir, "this@node")
      assert %{beat_ok?: true} = state
      {state, second} = tick_log(dir, state)
      assert %{beat_ok?: true} = state

      refute File.exists?(DirId.path(dir))
      assert beat_of("this@node").dir_id == nil
      assert first =~ "no id for the backup directory"
      assert first =~ ":eacces"
      assert second == ""

      # A new boot warns again.
      {_state, again} = tick_log(dir, "this@node")
      assert again =~ "no id for the backup directory"

      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert goods(dir) == synced(@cron)
    end

    test "enabled?/0 follows KILN_BACKUP_MARKER_SYNC_CRON" do
      assert MarkerSyncWorker.enabled?()
      put_cron("false")
      refute MarkerSyncWorker.enabled?()
      put_cron("5 * * * *")
      assert MarkerSyncWorker.enabled?()
      put_cron("not a cron")
      refute MarkerSyncWorker.enabled?()
    end
  end

  # #3079: the job's backup-directory I/O runs in tasks it waits on for a
  # bounded time, so a hung BACKUP_DIR can't hold an Oban slot.
  describe "a backup directory that hangs (#3079)" do
    # A one-argument seam that announces itself as `{tag, pid}` and blocks
    # until released with its answer, as I/O on a hung mount would.
    defp blocking(tag) do
      parent = self()

      fn _dir ->
        send(parent, {tag, self()})

        receive do
          {:release, result} -> result
        end
      end
    end

    # Every id read blocks; the job waits `timeout_ms` for it.
    defp blocking_reader!(timeout_ms \\ 50) do
      # A blocked task is left running on purpose; a test must not leave it
      # to the next one, nor to the sandbox's check-in.
      on_exit(&kill_io_tasks/0)
      put_backups_env(marker_sync_dir_reader: blocking(:reader), dir_id_timeout_ms: timeout_ms)
    end

    defp kill_io_tasks do
      for pid <- io_tasks() do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end
    end

    defp io_tasks, do: Task.Supervisor.children(KilnCMS.Backups.MarkerSyncIO)

    defp put_backups_env(opts) do
      env = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(env, opts))
    end

    defp release(pid, result) do
      ref = Process.monitor(pid)
      send(pid, {:release, result})
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    # Two jobs that gave up on their id read, whose reads are still blocked.
    defp two_abandoned! do
      for _ <- 1..2 do
        assert {:error, :backup_dir_unresponsive} = perform_job(MarkerSyncWorker, %{})
        assert_received {:reader, reader}
        reader
      end
    end

    test "an id read that hangs gives up promptly: an event, a warning, no marker, and the " <>
           "read is left running",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      blocking_reader!()
      ref = attach([[:kiln_cms, :backups, :marker_sync, :timeout]])

      {{micros, result}, log} =
        with_log([level: :warning], fn ->
          :timer.tc(fn -> perform_job(MarkerSyncWorker, %{}) end)
        end)

      assert result == {:error, :backup_dir_unresponsive}
      assert micros < 1_000_000

      assert_received {[:kiln_cms, :backups, :marker_sync, :timeout], ^ref,
                       %{count: 1, waited_ms: 50}, %{phase: :dir_id}}

      assert log =~ "the id read of the backup directory #{dir} took more than 50 ms"
      assert goods(dir) == []

      assert_received {:reader, reader}
      assert Process.alive?(reader)
      assert io_tasks() == [reader]
    end

    test "through Oban, the job fails promptly", %{dir: dir} do
      cron_backup!(dir, @cron)
      blocking_reader!()
      {:ok, job} = Oban.insert(MarkerSyncWorker.new(%{}))

      {micros, result} = :timer.tc(fn -> Oban.drain_queue(queue: :default) end)

      assert %{discard: 1, success: 0} = result
      assert micros < 1_000_000

      assert %{state: "discarded", errors: [%{"error" => error}]} =
               KilnCMS.Repo.get!(Oban.Job, job.id)

      assert error =~ "backup_dir_unresponsive"
      assert goods(dir) == []
    end

    test "the cron job still queues the other directories' jobs" do
      blocking_reader!()
      other = Ash.UUID.generate()
      beat!(other)

      assert {:error, :backup_dir_unresponsive} = perform_job(MarkerSyncWorker, %{})
      assert [%{args: %{"dir" => ^other}}] = all_enqueued(worker: MarkerSyncWorker)
    end

    test "a per-directory job whose id read hangs snoozes, so another node can take it",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      blocking_reader!()
      ref = attach([[:kiln_cms, :backups, :marker_sync, :timeout]])

      assert {:snooze, 30} = perform_job(MarkerSyncWorker, %{"dir" => Ash.UUID.generate()})
      assert_received {[:kiln_cms, :backups, :marker_sync, :timeout], ^ref, _, %{phase: :dir_id}}
      assert goods(dir) == []
    end

    for {kind, args} <- [{"a per-directory job", :routed}, {"the cron job", :cron}] do
      test "#{kind} whose sync hangs gives up promptly, with an event and a warning",
           %{dir: dir} do
        cron_backup!(dir, @cron)
        {:ok, local} = DirId.local(dir)
        on_exit(&kill_io_tasks/0)
        put_backups_env(marker_sync_syncer: blocking(:syncer), marker_sync_io_timeout_ms: 50)
        ref = attach([[:kiln_cms, :backups, :marker_sync, :timeout]])
        args = if unquote(args) == :routed, do: %{"dir" => local}, else: %{}

        {{micros, result}, log} =
          with_log([level: :warning], fn ->
            :timer.tc(fn -> perform_job(MarkerSyncWorker, args) end)
          end)

        assert result == {:error, :backup_dir_unresponsive}
        assert micros < 1_000_000
        assert micros < MarkerSyncWorker.timeout(%Oban.Job{args: args}) * 1000

        assert_received {[:kiln_cms, :backups, :marker_sync, :timeout], ^ref,
                         %{count: 1, waited_ms: 50}, %{phase: :sync}}

        assert log =~ "the marker sync of the backup directory #{dir} took more than 50 ms"
        assert_received {:syncer, syncer}
        assert Process.alive?(syncer)
        assert goods(dir) == []
      end
    end

    test "tasks a job still waits on are not limited: three healthy reads at once all answer" do
      put_backups_env(marker_sync_dir_reader: blocking(:reader), dir_id_timeout_ms: 5_000)
      on_exit(&kill_io_tasks/0)
      here = Ash.UUID.generate()

      jobs =
        for _ <- 1..3 do
          Task.async(fn -> perform_job(MarkerSyncWorker, %{"dir" => Ash.UUID.generate()}) end)
        end

      readers =
        for _ <- 1..3 do
          assert_receive {:reader, reader}
          reader
        end

      assert length(io_tasks()) == 3
      Enum.each(readers, &send(&1, {:release, {:ok, here}}))

      # Another directory's id: each snoozes, none is refused as busy.
      assert Enum.map(jobs, &Task.await/1) == [{:snooze, 30}, {:snooze, 30}, {:snooze, 30}]
    end

    test "with two abandoned tasks still blocked, the next job starts none and fails as busy",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      blocking_reader!()
      two_abandoned!()

      {result, log} = with_log([level: :warning], fn -> perform_job(MarkerSyncWorker, %{}) end)

      assert result == {:error, :backup_dir_io_busy}
      refute_received {:reader, _}
      assert log =~ "didn't start the id read of #{dir}: 2 earlier ones it gave up on"
      assert goods(dir) == []
    end

    test "an abandoned task that finishes frees its slot, and says how long it took",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      blocking_reader!()
      [first, _second] = two_abandoned!()

      # An info line, below the test config's level (this module is not async).
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :info], fn ->
          release(first, {:error, :enoent})
          # The tracker has handled the `:DOWN` once it answers.
          assert KilnCMS.Backups.MarkerSyncAbandoned.count() == 1
        end)

      assert log =~ ~r/the id read of #{Regex.escape(dir)} finished after \d+ s more/

      put_backups_env(marker_sync_dir_reader: fn _dir -> {:error, :enoent} end)
      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
    end

    test "an id read that crashes is no id: the cron job syncs in place", %{dir: dir} do
      cron_backup!(dir, @cron)
      on_exit(&kill_io_tasks/0)
      put_backups_env(marker_sync_dir_reader: fn _dir -> raise "boom" end)

      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
    end

    test "an id read that answers in time is used as before", %{dir: dir} do
      cron_backup!(dir, @cron)
      {:ok, local} = DirId.local(dir)
      on_exit(&kill_io_tasks/0)
      put_backups_env(dir_id_timeout_ms: 1_000)

      assert :ok = perform_job(MarkerSyncWorker, %{"dir" => local})
      assert goods(dir) == ["db/kiln-#{@cron}.good", "media/kiln-#{@cron}.good"]
      assert io_tasks() == []
    end

    test "the job's timeout outlasts both waits and sits well inside the rescue window" do
      rescue_after = KilnCMS.Application.oban_rescue_after()
      assert is_integer(rescue_after)
      job = %Oban.Job{args: %{}}

      assert MarkerSyncWorker.io_wait_ms() == 125_000
      assert MarkerSyncWorker.timeout(job) > MarkerSyncWorker.io_wait_ms()
      assert MarkerSyncWorker.timeout(job) + :timer.minutes(30) < rescue_after

      # Configured long waits move the timeout with them.
      put_backups_env(
        dir_id_timeout_ms: :timer.minutes(1),
        marker_sync_io_timeout_ms: :timer.minutes(20)
      )

      assert MarkerSyncWorker.io_wait_ms() == :timer.minutes(21)
      assert MarkerSyncWorker.timeout(job) > :timer.minutes(21)
    end
  end

  # #2931's acceptance: a backup a schedule keeps, deleted by a host prune
  # that ignores `.hold` (a `backup.sh` older than the hold markers), is
  # logged and reported at the next sync, and both Backups pages warn.
  describe "a held backup deleted outside the app (#2931)" do
    @endpoint KilnCMSWeb.Endpoint

    defp signed_in_conn(user) do
      strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(
          strategy,
          :sign_in,
          %{"email" => to_string(user.email), "password" => "password123456"},
          []
        )

      KilnCMSWeb.ConnCase.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
    end

    # The Backups page reads its status in the background (#2417).
    defp await_status(lv, tries \\ 20) do
      render_async(lv, 2_000)

      cond do
        has_element?(lv, ~s|#backup-page[data-busy="false"]|) -> :ok
        tries == 0 -> flunk("the Backups page was still busy")
        true -> await_status(lv, tries - 1)
      end
    end

    test "is reported, and both pages warn", %{dir: dir} do
      cron_backup!(dir, @old)
      assert :ok = perform_job(MarkerSyncWorker, %{})
      cron_backup!(dir, @cron)
      BackupSchedules.schedule!(%{keep_count: 2})
      assert :ok = perform_job(MarkerSyncWorker, %{})
      assert holds(dir) == ["db/kiln-#{@old}.hold", "db/kiln-#{@cron}.hold"]

      ref = attach([[:kiln_cms, :backups, :hold, :deleted_outside]])
      File.rm!(Path.join([dir, "db", "kiln-db-#{@old}.dump"]))

      log =
        capture_log([level: :warning], fn -> assert :ok = perform_job(MarkerSyncWorker, %{}) end)

      assert log =~
               "deleted outside the app although their .hold markers kept them: " <>
                 "db backup #{@old}."

      assert_received {[:kiln_cms, :backups, :hold, :deleted_outside], ^ref, %{count: 1},
                       %{scope: :local}}

      assert holds(dir) == ["db/kiln-#{@cron}.hold"]

      line =
        "a backup a schedule keeps was deleted outside the app: " <>
          "Database backup of 2026-07-01 03:17 UTC."

      conn = signed_in_conn(BackupSchedules.platform_admin())

      {:ok, lv, _html} = live(conn, "/editor/backups")
      await_status(lv)
      assert has_element?(lv, "#backup-held-deleted", line)
      assert has_element?(lv, ~s|#backup-held-deleted-docs[href$="backups.md#the-hold-markers"]|)

      {:ok, lv, _html} = live(conn, "/editor/backups/schedules")
      assert has_element?(lv, "#schedule-held-deleted", line)
      assert has_element?(lv, "#schedule-held-deleted", "scripts/backup.sh is older than this")

      # The next sync has nothing more to say.
      assert :ok = perform_job(MarkerSyncWorker, %{})
      refute_received {[:kiln_cms, :backups, :hold, :deleted_outside], ^ref, _, _}
    end
  end
end
