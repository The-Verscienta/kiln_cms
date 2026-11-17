defmodule KilnCMS.Backups.DestinationRetentionTest do
  @moduledoc """
  Retention on an off-site destination (#2220, plan step S7, ADR 0064):
  `Retention.run_on_destination/3` against the test-only Fake adapter, whose
  listing a test sets and whose deletes it sees, and the off-site step
  pruning a stored Local destination after a real backup reached it.

  `async: false`: `Application` env (the backup directory, the adapters, the
  rclone remote) and PATH are VM-global.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.Test.BackupDestinations, only: [fake_config: 1]

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Retention}
  alias KilnCMS.Backups.Retention.Policy
  alias KilnCMS.Test.{BackupChain, BackupSchedules}

  @moduletag :capture_log

  @day 86_400
  # Every unit below is years old by its stamp; `now` is fixed.
  @now DateTime.to_unix(~U[2026-11-15 12:00:00Z])
  @a "20200101-000000"
  @f "20200115-000000"
  @b "20200201-000000"
  @c "20200301-000000"

  defmodule Bare do
    @moduledoc "A destination adapter that declares no `supports/0`."
    use Kiln.BackupDestination

    @impl Kiln.BackupDestination
    def kind, do: "bare_test"
    @impl Kiln.BackupDestination
    def label, do: "Bare (test)"
    @impl Kiln.BackupDestination
    def fields, do: []
    @impl Kiln.BackupDestination
    def validate(_config), do: :ok
    @impl Kiln.BackupDestination
    def test(_config), do: :ok
    @impl Kiln.BackupDestination
    def put(_config, _file, _opts), do: :ok

    @impl Kiln.BackupDestination
    def list(config) do
      send(config.settings["notify"], {:bare, :list})
      {:ok, []}
    end

    @impl Kiln.BackupDestination
    def get(_config, _ref, _to), do: :ok

    @impl Kiln.BackupDestination
    def delete(config, _ref) do
      send(config.settings["notify"], {:bare, :delete})
      :ok
    end

    @impl Kiln.BackupDestination
    def describe(_config), do: "bare"
  end

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_dret_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "backups")
    for sub <- ["db", "media", ".work"], do: File.mkdir_p!(Path.join(dir, sub))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    original_dest = Application.get_env(:kiln_cms, KilnCMS.Backups.Destination, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, enabled: true, dir: dir, media_dir: nil, keep_days: 14)
    )

    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
      Application.put_env(:kiln_cms, KilnCMS.Backups.Destination, original_dest)
      File.rm_rf!(base)
    end)

    %{base: base, dir: dir, key: "dest:" <> Ecto.UUID.generate()}
  end

  # -- helpers ---------------------------------------------------------------

  # A db unit as a destination lists it: the dump and its sidecar.
  defp listed(stamp, mtime \\ nil) do
    mtime = mtime || DateTime.from_unix!(@now - 400 * @day)

    [
      %{subdir: "db", name: "kiln-db-#{stamp}.dump", bytes: 10, mtime: mtime},
      %{subdir: "db", name: Artifact.sidecar_name(:db, stamp), bytes: 80, mtime: mtime}
    ]
  end

  # A finished app run of `stamp` whose dump was sent to each of `keys`.
  defp run!(stamp, keys, status \\ :succeeded) do
    {:ok, artifact} =
      Artifact.from_manifest(%{kind: "db", path: "db/kiln-db-#{stamp}.dump", verified: true})

    sent = Map.new(keys, &{&1, %{"status" => "ok"}})
    artifact = Map.update!(artifact, :destinations, &Map.merge(&1, sent))

    run =
      Backups.start_run!(
        %{stamp: stamp, trigger: "manual", started_at: ~U[2020-01-01 00:00:00Z]},
        actor: Backups.system()
      )

    case status do
      :succeeded ->
        Backups.finish_run!(run, %{artifacts: [artifact]}, actor: Backups.system())

      :failed ->
        Backups.fail_run!(run, %{artifacts: [artifact]}, actor: Backups.system())

      :running ->
        Backups.record_run_progress!(run, %{artifacts: [artifact]}, actor: Backups.system())
    end
  end

  defp stored(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())

  defp prune(dir, config, opts \\ []) do
    Retention.run_on_destination(
      dir,
      config,
      Keyword.merge([policy: Policy.legacy(14), now: @now], opts)
    )
  end

  defp fake(key, settings), do: %{fake_config(settings) | key: key}

  # Every delete the Fake was asked for, in order.
  defp deletes do
    receive do
      {:fake_destination, :delete, [%{name: name}], _pid} -> [name | deletes()]
    after
      0 -> []
    end
  end

  defp dump_and_sidecar(stamp), do: ["kiln-db-#{stamp}.dump", Artifact.sidecar_name(:db, stamp)]

  # -- the plan, against the Fake ----------------------------------------------

  describe "run_on_destination/3" do
    test "deletes only owned, aged units, data before the sidecar; never the newest verified " <>
           "or the newest complete",
         %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      # Newest by stamp, its run failed: the newest complete, not verified.
      run!(@c, [key], :failed)

      config = fake(key, %{"entries" => listed(@a) ++ listed(@b) ++ listed(@c)})

      assert {:ok, %{deleted: deleted, units: 1, stopped: nil, unowned: []}} =
               prune(dir, config)

      assert deleted == dump_and_sidecar(@a)
      assert deletes() == dump_and_sidecar(@a)
    end

    test "leaves a unit this installation has no record of sending there, and reports it", %{
      dir: dir,
      key: key
    } do
      run!(@a, [key])
      run!(@b, [key])
      # Sent somewhere else: the same kind of record, another key.
      run!(@f, ["dest:" <> Ecto.UUID.generate()])
      other = "20200110-000000"

      config =
        fake(key, %{"entries" => listed(@a) ++ listed(@f) ++ listed(other) ++ listed(@b)})

      assert {:ok, %{deleted: deleted, unowned: unowned}} = prune(dir, config)
      assert deleted == dump_and_sidecar(@a)
      assert Enum.map(unowned, & &1.stamp) |> Enum.sort() == [other, @f]
      refute Enum.any?(deletes(), &(&1 =~ @f or &1 =~ other))
    end

    test "marks the deleted files pruned under that key on their runs, and nothing else", %{
      dir: dir,
      key: key
    } do
      run!(@a, [key])
      run!(@b, [key])

      assert {:ok, %{deleted: [_, _]}} =
               prune(dir, fake(key, %{"entries" => listed(@a) ++ listed(@b)}))

      assert [%{destinations: pruned}] = stored(@a).artifacts
      assert pruned[key]["status"] == "pruned"
      assert pruned["local"]["status"] == "ok"

      assert [%{destinations: kept}] = stored(@b).artifacts
      assert kept[key]["status"] == "ok"
    end

    test "a local .keep pins the remote unit", %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      File.write!(Path.join([dir, "db", Artifact.keep_name(@a)]), "")

      assert {:ok, %{deleted: []}} =
               prune(dir, fake(key, %{"entries" => listed(@a) ++ listed(@b)}))

      assert deletes() == []
    end

    test "keeps a unit in flight: a local .work directory, or a running run", %{
      dir: dir,
      key: key
    } do
      run!(@a, [key])
      run!(@f, [key], :running)
      run!(@b, [key])
      File.mkdir_p!(Path.join([dir, ".work", @a]))

      config = fake(key, %{"entries" => listed(@a) ++ listed(@f) ++ listed(@b)})

      assert {:ok, %{deleted: []}} = prune(dir, config)
      assert deletes() == []
    end

    test "a unit's age is the later of its remote mtime and its stamp", %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@f, [key])
      run!(@b, [key])

      # Copied two days ago: young, whatever its stamp says.
      recent = DateTime.from_unix!(@now - 2 * @day)
      # A store that reports no mtime: aged by the stamp alone.
      unknown =
        Enum.map(listed(@f), &Map.put(&1, :mtime, nil))

      config = fake(key, %{"entries" => listed(@a, recent) ++ unknown ++ listed(@b)})

      assert {:ok, %{deleted: deleted}} = prune(dir, config)
      assert deleted == dump_and_sidecar(@f)
    end

    test "a listing that fails deletes nothing", %{dir: dir, key: key} do
      run!(@a, [key])

      config =
        fake(key, %{"list_mode" => "fail", "entries" => listed(@a) ++ listed(@b)})

      assert {:error, {:list, message} = reason} = prune(dir, config)
      refute message =~ "fake-secret-token-123"
      assert Retention.describe(reason) =~ "couldn't list the destination"
      assert deletes() == []
    end

    test "a policy that can't be read deletes nothing", %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      config = fake(key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:error, {:policy, :nope}} =
               prune(dir, config, policy: fn -> {:error, :nope} end)

      assert deletes() == []
    end

    test "stops at a delete that times out", %{dir: dir, key: key} do
      for stamp <- [@a, @f, @b], do: run!(stamp, [key])

      config =
        fake(key, %{
          "delete_mode" => "sleep",
          "sleep_ms" => 5_000,
          "entries" => listed(@a) ++ listed(@f) ++ listed(@b)
        })

      assert {:ok, %{deleted: [], units: 0, stopped: {:delete, name, reason}}} =
               prune(dir, config, timeout: 100)

      assert name == "kiln-db-#{@a}.dump"
      assert KilnCMS.Backups.Destination.timed_out?(reason)
      # One delete asked for; nothing after it.
      assert deletes() == [name]
      assert [%{destinations: %{^key => %{"status" => "ok"}}}] = stored(@a).artifacts
    end

    test "an adapter without supports/0 deletes nothing, and isn't even listed", %{
      dir: dir,
      key: key
    } do
      Application.put_env(:kiln_cms, KilnCMS.Backups.Destination,
        extra_adapters: [KilnCMS.Test.BackupDestinations.Fake, Bare]
      )

      config = %{fake(key, %{}) | kind: "bare_test"}

      assert {:error, :unsupported} = prune(dir, config)
      refute_received {:bare, _}
    end

    test "the env destination is never pruned", %{dir: dir} do
      env_key = "rclone:r2:kiln"
      run!(@a, [env_key])
      run!(@b, [env_key])

      config = fake(env_key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:error, :not_prunable} = prune(dir, config)
      refute_received {:fake_destination, :list, _, _}
      assert deletes() == []
    end
  end

  # -- where the destination writes, checked again before anything is listed --

  describe "run_on_destination/3 and overlapping locations" do
    defp env_remote!(remote) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, remote)
      )
    end

    defp rclone_config(settings) do
      id = Ecto.UUID.generate()
      %Config{id: id, key: "dest:" <> id, kind: "rclone", settings: settings, secrets: %{}}
    end

    test "a destination inside BACKUP_RCLONE_REMOTE is skipped, nothing listed", %{dir: dir} do
      env_remote!("r2:kiln")
      config = rclone_config(%{"remote_name" => "r2", "path" => "kiln/site"})

      assert {:error, :env_overlap = reason} = prune(dir, config)
      assert Retention.describe(reason) == "it overlaps BACKUP_RCLONE_REMOTE"
    end

    test "with BACKUP_RCLONE_REMOTE unset, a plugin's destination is pruned as before",
         %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      run!(@c, [key])
      config = fake(key, %{"entries" => listed(@a) ++ listed(@b) ++ listed(@c)})
      env_remote!(nil)

      assert {:ok, %{deleted: [_ | _]}} = prune(dir, config)
    end

    test "a plugin's destination, whose location can't be told, is skipped while " <>
           "BACKUP_RCLONE_REMOTE is set",
         %{dir: dir, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      config = fake(key, %{"entries" => listed(@a) ++ listed(@b)})
      env_remote!("r2:kiln")

      assert {:error, :env_overlap_unknown = reason} = prune(dir, config)
      assert Retention.describe(reason) == "can't confirm it doesn't overlap BACKUP_RCLONE_REMOTE"
      refute_received {:fake_destination, :list, _, _}
      assert deletes() == []
    end

    test "an S3 destination is skipped while BACKUP_RCLONE_REMOTE is set: a remote may name " <>
           "the same bucket (#2221)",
         %{dir: dir} do
      env_remote!("r2:kiln")
      id = Ecto.UUID.generate()

      config = %Config{
        id: id,
        key: "dest:" <> id,
        kind: "s3",
        settings: %{"endpoint" => "https://s3.test", "region" => "auto", "bucket" => "kiln"},
        secrets: %{}
      }

      assert {:error, :env_overlap_unknown} = prune(dir, config)
    end

    @tag :tmp_dir
    test "a destination overlapping another stored one is skipped; its own row is not an overlap",
         %{dir: dir, tmp_dir: tmp_dir} do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :local_destination_roots, [
          tmp_dir
        ])
      )

      path = Path.join(tmp_dir, "site")
      File.mkdir_p!(path)

      row =
        Backups.create_backup_destination!(
          %{name: "Disk", kind: "local", settings: %{"path" => path}},
          actor: BackupSchedules.platform_admin()
        )

      # A row saved before the other existed, or by a release without the
      # check: inside the stored one.
      id = Ecto.UUID.generate()

      inner = %Config{
        id: id,
        key: "dest:" <> id,
        kind: "local",
        settings: %{"path" => Path.join(path, "inner")},
        secrets: %{}
      }

      assert {:error, :destination_overlap = reason} = prune(dir, inner)
      assert Retention.describe(reason) == "it overlaps another backup destination"

      own = %Config{
        id: row.id,
        key: "dest:" <> row.id,
        kind: "local",
        settings: %{"path" => path},
        secrets: %{}
      }

      assert {:ok, %{deleted: []}} = prune(dir, own)
    end
  end

  # -- after a real backup -----------------------------------------------------

  describe "the off-site step" do
    @describetag :pg_tools

    # A Local destination's directory, seeded with backups as an earlier run
    # (or another installation) left them, 400 days old.
    defp seed(path, stamps) do
      for stamp <- stamps, name <- dump_and_sidecar(stamp) do
        file = Path.join([path, "db", name])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, "old #{name}")
        File.touch!(file, System.os_time(:second) - 400 * @day)
      end
    end

    defp current_run do
      Backups.list_runs!(actor: Backups.system())
      |> Enum.max_by(& &1.started_at, DateTime)
    end

    defp local!(tmp_dir, attrs \\ %{}) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :local_destination_roots, [
          tmp_dir
        ])
      )

      path = Path.join(tmp_dir, "site")
      File.mkdir_p!(path)

      row =
        Backups.create_backup_destination!(
          Map.merge(%{name: "Disk", kind: "local", settings: %{"path" => path}}, attrs),
          actor: BackupSchedules.platform_admin()
        )

      {row, path}
    end

    defp present?(path, stamp),
      do: Enum.all?(dump_and_sidecar(stamp), &File.regular?(Path.join([path, "db", &1])))

    # `:tmp_dir`: a Local destination's path may hold no symlink, and the
    # system temp directory sits behind one on macOS.
    @tag :tmp_dir
    test "prunes what this installation sent there, reports the rest, and counts it on the run",
         %{tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir)
      key = "dest:" <> row.id
      run!(@a, [key])
      run!(@b, [key])
      seed(path, [@a, @f, @b])

      assert :ok = BackupChain.run()
      run = current_run()

      assert run.offsite_status == :complete
      assert %{status: :ok, pruned: 1} = Enum.find(run.destinations, &(&1.key == key))

      refute present?(path, @a)
      assert present?(path, @f)
      assert present?(path, @b)
      assert present?(path, run.stamp)

      messages = Enum.map(run.log, & &1.message)
      assert "Retention on Disk removed 2 file(s) from 1 backup(s)" in messages
      assert Enum.any?(messages, &(&1 =~ "Retention on Disk left 1 old backup(s)" and &1 =~ @f))

      assert [%{destinations: %{^key => %{"status" => "pruned"}}}] = stored(@a).artifacts
    end

    @tag :tmp_dir
    test "with prune off, nothing is deleted", %{tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir, %{prune: false})
      key = "dest:" <> row.id
      run!(@a, [key])
      run!(@b, [key])
      seed(path, [@a, @b])

      # #2487: an earlier skip there is cleared, since nothing prunes it now.
      Backups.report_backup_notice!(
        %{kind: :retention, scope: key, outcome: :skipped, reason: "x", at: DateTime.utc_now()},
        actor: Backups.system()
      )

      assert :ok = BackupChain.run()

      assert present?(path, @a)
      assert %{pruned: 0} = Enum.find(current_run().destinations, &(&1.key == key))
      assert Backups.list_backup_notices!(actor: Backups.system()) == []
    end

    test "a listing that fails logs the skipped line; the destination stays reached" do
      row =
        KilnCMS.Test.BackupDestinations.destination!(%{
          name: "Bucket",
          settings: %{"mode" => "ok", "list_mode" => "fail"}
        })

      key = "dest:" <> row.id

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:kiln_cms, :backups, :retention, :skipped]
        ])

      assert :ok = BackupChain.run()

      # #2487: the same event local retention emits, scoped to the
      # destination, and a notice naming it.
      assert_received {[:kiln_cms, :backups, :retention, :skipped], ^ref, %{count: 1},
                       %{scope: :destination, destination: ^key, reason: {:list, _}}}

      assert [
               %{
                 scope: {:destination, ^key},
                 label: "Bucket",
                 outcome: :skipped,
                 reason: "couldn't list the destination" <> _
               }
             ] = Backups.status().retention

      run = current_run()

      assert run.offsite_status == :complete

      assert %{status: :ok, pruned: 0} =
               Enum.find(run.destinations, &(&1.key == "dest:" <> row.id))

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message =~ "Retention on Bucket skipped: couldn't list the destination" and
                   &1.message =~ "nothing was deleted")
             )

      # A clean pass there clears it.
      Backups.update_backup_destination!(row, %{settings: %{"mode" => "ok"}},
        actor: KilnCMS.Test.BackupSchedules.platform_admin()
      )

      assert :ok = BackupChain.run()
      assert Backups.status().retention == []
    end

    # An rclone that logs its argv to the returned path and succeeds, with
    # `BACKUP_RCLONE_REMOTE` set to `r2:kiln`.
    defp env_rclone!(base) do
      bin = Path.join(base, "bin")
      log = Path.join(base, "rclone.log")
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "rclone"), """
      #!/bin/sh
      echo "$*" >> "#{log}"
      exit 0
      """)

      File.chmod!(Path.join(bin, "rclone"), 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, "r2:kiln")
      )

      log
    end

    test "a plugin's destination beside BACKUP_RCLONE_REMOTE is reached but not pruned",
         %{base: base} do
      env_rclone!(base)

      row =
        KilnCMS.Test.BackupDestinations.destination!(%{
          name: "Bucket",
          settings: %{"mode" => "ok"}
        })

      key = "dest:" <> row.id
      run!(@a, [key])
      run!(@b, [key])

      assert :ok = BackupChain.run()
      run = current_run()

      assert run.offsite_status == :complete
      assert %{status: :ok, pruned: 0} = Enum.find(run.destinations, &(&1.key == key))

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message ==
                     "Retention on Bucket skipped: can't confirm it doesn't overlap " <>
                       "BACKUP_RCLONE_REMOTE; nothing was deleted")
             )
    end

    # A Local row saved while BACKUP_RCLONE_REMOTE pointed elsewhere, then
    # the env remote moved over it: retention must not reach the env copy.
    @tag :tmp_dir
    test "a destination BACKUP_RCLONE_REMOTE now overlaps is reached but not pruned",
         %{base: base, tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir)
      key = "dest:" <> row.id
      run!(@a, [key])
      run!(@b, [key])
      seed(path, [@a, @f, @b])

      env_rclone!(base)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote, tmp_dir)
      )

      assert :ok = BackupChain.run()
      run = current_run()

      assert %{status: :ok, pruned: 0} = Enum.find(run.destinations, &(&1.key == key))
      assert present?(path, @a)

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message ==
                     "Retention on Disk skipped: it overlaps BACKUP_RCLONE_REMOTE; " <>
                       "nothing was deleted")
             )
    end

    test "the env destination is never listed or pruned, even with an old unit recorded on its key",
         %{base: base} do
      log = env_rclone!(base)

      run!(@a, ["rclone:r2:kiln"])
      run!(@b, ["rclone:r2:kiln"])

      assert :ok = BackupChain.run()

      calls = log |> File.read!() |> String.split("\n", trim: true)
      assert calls != []
      assert Enum.all?(calls, &String.starts_with?(&1, "copy "))
      assert [%{destinations: %{"rclone:r2:kiln" => %{"status" => "ok"}}}] = stored(@a).artifacts
    end
  end
end
