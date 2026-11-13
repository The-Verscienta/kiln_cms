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

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, DirId, Heartbeat, MarkerSyncWorker}

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

    test "one live job per directory: the next slot does not stack another behind it" do
      dir_id = Ash.UUID.generate()

      assert {:ok, %{conflict?: false}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{"dir" => dir_id}))
      assert {:ok, %{conflict?: false}} = Oban.insert(MarkerSyncWorker.new(%{}))
      assert {:ok, %{conflict?: true}} = Oban.insert(MarkerSyncWorker.new(%{}))
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
end
