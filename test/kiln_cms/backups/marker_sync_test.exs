defmodule KilnCMS.Backups.MarkerSyncTest do
  @moduledoc """
  The last-good marker for cron-only deployments (#2554): `MarkerSyncWorker`
  and `Chain.sync_last_good/2`. A cron-made backup gets its `.good` marker
  with nobody running a command; the sync writes nothing while a chain holds
  the lock, routes by backup directory only when the nodes report one, and
  fails closed. That a sync and a request are serialized needs two real
  connections: it is in `ChainRaceTest`.

  `async: false`: points the VM-wide backup directory at a temporary one and
  changes the `:backup_marker_sync_cron` key.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, DirId, Manifest, MarkerSyncWorker}

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

  # What `backup.sh` leaves: a dump, a media archive and the manifest of the
  # run (which lets the importer take brand-new files without a settle wait).
  defp cron_backup!(dir, stamp) do
    File.write!(Path.join([dir, "db", "kiln-db-#{stamp}.dump"]), "dump")
    File.write!(Path.join([dir, "media", "kiln-media-#{stamp}.tar.gz"]), "tar")
    {:ok, at} = Artifact.parse_stamp(stamp)

    :ok =
      Manifest.write(
        dir,
        struct!(Manifest,
          trigger: "cron",
          ok: true,
          started_at: at,
          finished_at: DateTime.add(at, 60),
          artifacts: [
            %{kind: "db", path: "db/kiln-db-#{stamp}.dump", bytes: 4, verified: true},
            %{kind: "media", path: "media/kiln-media-#{stamp}.tar.gz", bytes: 3, verified: true}
          ]
        )
      )
  end

  defp old_marker!(dir), do: File.write!(Path.join([dir, "db", Artifact.good_name(@old)]), "")

  # Sorted: `File.ls!/1` returns directory order.
  defp goods(dir) do
    for sub <- ["db", "media"],
        name <- Enum.sort(File.ls!(Path.join(dir, sub))),
        String.ends_with?(name, ".good"),
        do: "#{sub}/#{name}"
  end

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

    test "with ids reported, the cron job queues one job per directory and leaves an id'd one to it",
         %{dir: dir} do
      cron_backup!(dir, @cron)
      {:ok, local} = DirId.local(dir)
      other = Ash.UUID.generate()
      beat!(local)
      beat!(other)
      beat!(nil)

      assert :ok = perform_job(MarkerSyncWorker, %{})

      assert_enqueued(worker: MarkerSyncWorker, args: %{"dir" => local})
      assert_enqueued(worker: MarkerSyncWorker, args: %{"dir" => other})
      assert length(all_enqueued(worker: MarkerSyncWorker)) == 2
      # This node's directory has an id: its own job syncs it.
      assert goods(dir) == []
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
end
