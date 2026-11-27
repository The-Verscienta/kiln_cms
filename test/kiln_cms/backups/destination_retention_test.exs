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
  alias KilnCMS.Backups.{Artifact, Destination, DestinationConfig, DirId, Retention}
  alias KilnCMS.Backups.Destination.{Rclone, Sftp}
  alias KilnCMS.Backups.Retention.Policy
  alias KilnCMS.Test.{BackupChain, BackupSchedules, SftpServer}

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

    # The backup directory's id: only its in-app runs' backups are pruned.
    {:ok, dir_id} = DirId.local(dir)

    %{base: base, dir: dir, dir_id: dir_id, key: "dest:" <> Ecto.UUID.generate()}
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

  # A finished app run of `stamp` whose dump was sent to each of `keys`;
  # `attrs` go to its start. Its `dir_id` is the backup directory's own
  # (created when there is none) unless `attrs` names another, or nil.
  defp run!(stamp, keys, status \\ :succeeded, attrs \\ %{}) do
    attrs = Map.put_new_lazy(attrs, :dir_id, fn -> own_dir_id() end)

    {:ok, artifact} =
      Artifact.from_manifest(%{kind: "db", path: "db/kiln-db-#{stamp}.dump", verified: true})

    sent = Map.new(keys, &{&1, %{"status" => "ok"}})
    artifact = Map.update!(artifact, :destinations, &Map.merge(&1, sent))

    run =
      Backups.start_run!(
        Map.merge(
          %{stamp: stamp, trigger: "manual", started_at: ~U[2020-01-01 00:00:00Z]},
          attrs
        ),
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

  # A cron-made run of `stamp`, imported, whose dump cron sent to `key`.
  defp imported!(stamp, key) do
    {:ok, artifact} =
      Artifact.from_manifest(%{kind: "db", path: "db/kiln-db-#{stamp}.dump", verified: true})

    artifact = Map.update!(artifact, :destinations, &Map.put(&1, key, %{"status" => "ok"}))
    at = ~U[2020-01-01 00:00:00Z]

    Backups.import_run!(
      %{
        stamp: stamp,
        trigger: "cron",
        status: :succeeded,
        components: [:db],
        started_at: at,
        finished_at: at,
        artifacts: [artifact]
      },
      actor: Backups.system()
    )
  end

  defp own_dir_id do
    {:ok, id} = DirId.local(Backups.dir())
    id
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

      # The step has an hour left; the delete's own bound stops it (#2950).
      step_deadline = System.monotonic_time(:millisecond) + :timer.hours(1)
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{deleted: [], units: 0, stopped: {:delete, name, reason}}} =
               prune(dir, config, deadline: step_deadline, delete_call_ms: 100)

      assert System.monotonic_time(:millisecond) - started < 4_000

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

    test "a listing that hangs is cut at its own bound, long before the step's deadline " <>
           "(#2950)",
         %{dir: dir, key: key} do
      run!(@a, [key])

      config =
        fake(key, %{
          "list_mode" => "sleep",
          "sleep_ms" => 10_000,
          "entries" => listed(@a) ++ listed(@b)
        })

      step_deadline = System.monotonic_time(:millisecond) + :timer.hours(1)
      started = System.monotonic_time(:millisecond)

      assert {:error, {:list, reason}} =
               prune(dir, config, deadline: step_deadline, list_call_ms: 100)

      assert KilnCMS.Backups.Destination.timed_out?(reason)
      assert System.monotonic_time(:millisecond) - started < 5_000
      assert deletes() == []
    end

    test "the step's deadline still bounds a call when it comes before the call's own",
         %{dir: dir, key: key} do
      config = fake(key, %{"list_mode" => "sleep", "sleep_ms" => 10_000})
      started = System.monotonic_time(:millisecond)

      assert {:error, {:list, reason}} =
               prune(dir, config, deadline: System.monotonic_time(:millisecond) + 100)

      assert KilnCMS.Backups.Destination.timed_out?(reason)
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "the env destination is not pruned while BACKUP_RCLONE_REMOTE_PRUNE is off", %{
      dir: dir
    } do
      env_remote!("r2:kiln")
      env_key = Destination.env_key("r2:kiln")
      {:ok, dir_id} = DirId.local(dir)
      run!(@a, [env_key], :succeeded, %{dir_id: dir_id})
      run!(@b, [env_key], :succeeded, %{dir_id: dir_id})

      config = fake(env_key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:error, :not_prunable} = prune(dir, config)
      refute_received {:fake_destination, :list, _, _}
      assert deletes() == []
    end
  end

  # -- BACKUP_RCLONE_REMOTE, by opt-in (#2950) ----------------------------------

  # A stored destination is pruned only of what in-app backups of this
  # backup directory sent there, or of a directory it adopted for this one:
  # a database restored on another server carries the original server's
  # destinations and run history, and must not prune that server's backups.
  describe "run_on_destination/3: whose backups a stored destination prunes" do
    defp stored_adoptions(row),
      do: Backups.get_backup_destination!(row.id, actor: Backups.system()).adoptions

    defp adoption(dir_id, adopted_by),
      do: %{
        "dir_id" => dir_id,
        "adopted_by" => adopted_by,
        "adopted_at" => "2026-11-19T00:00:00Z"
      }

    test "only this directory's in-app backups; another directory's, cron's and a run " <>
           "with no directory are kept",
         %{dir: dir, key: key} do
      other = "20200105-000000"
      no_dir = "20200108-000000"

      run!(@a, [key])
      run!(other, [key], :succeeded, %{dir_id: Ecto.UUID.generate()})
      run!(no_dir, [key], :succeeded, %{dir_id: nil})
      imported!(@f, key)
      run!(@b, [key])

      config = fake(key, %{"entries" => Enum.flat_map([@a, other, no_dir, @f, @b], &listed/1)})

      assert {:ok, %{deleted: deleted, unowned: unowned, other_directory: elsewhere}} =
               prune(dir, config)

      assert deleted == dump_and_sidecar(@a)
      assert deletes() == dump_and_sidecar(@a)
      assert Enum.map(unowned, & &1.stamp) |> Enum.sort() == Enum.sort([other, no_dir, @f])
      assert Enum.map(elsewhere, & &1.stamp) == [other]
    end

    test "a directory it adopted for this one is pruned too", %{
      dir: dir,
      dir_id: dir_id,
      key: key
    } do
      retired = Ecto.UUID.generate()
      run!(@a, [key], :succeeded, %{dir_id: retired})
      run!(@b, [key])

      config = fake(key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:ok, %{deleted: [], other_directory: [%{stamp: @a}]}} = prune(dir, config)

      assert {:ok, %{deleted: deleted, other_directory: []}} =
               prune(dir, config, adoptions: [adoption(retired, [dir_id])])

      assert deleted == dump_and_sidecar(@a)
    end

    test "an adoption made for another backup directory doesn't apply to this one", %{
      dir: dir,
      key: key
    } do
      retired = Ecto.UUID.generate()
      run!(@a, [key], :succeeded, %{dir_id: retired})
      run!(@b, [key])

      config = fake(key, %{"entries" => listed(@a) ++ listed(@b)})
      adoptions = [adoption(retired, [Ecto.UUID.generate()])]

      assert {:ok, %{deleted: [], other_directory: [%{stamp: @a}]}} =
               prune(dir, config, adoptions: adoptions)

      assert deletes() == []
    end

    test "a database restored on another server deletes none of the original server's " <>
           "backups, its adoptions included",
         %{dir: dir, key: key} do
      # The original server's directory, and one it had adopted.
      production = Ecto.UUID.generate()
      adopted_there = Ecto.UUID.generate()
      newer = "20200401-000000"

      run!(@a, [key], :succeeded, %{dir_id: production})
      run!(@f, [key], :succeeded, %{dir_id: adopted_there})
      run!(@b, [key], :succeeded, %{dir_id: production})
      run!(@c, [key], :succeeded, %{dir_id: production})
      run!(newer, [key], :succeeded, %{dir_id: production})

      config = fake(key, %{"entries" => Enum.flat_map([@a, @f, @b, @c, newer], &listed/1)})
      adoptions = [adoption(adopted_there, [production])]

      # This server's directory has an id of its own (the setup's).
      assert {:ok, %{deleted: [], units: 0, other_directory: elsewhere}} =
               prune(dir, config, adoptions: adoptions)

      # All but the newest, which the keep rules hold anyway.
      assert Enum.map(elsewhere, & &1.stamp) |> Enum.sort() == Enum.sort([@a, @f, @b, @c])
      assert deletes() == []

      for stamp <- [@a, @f, @b, @c] do
        assert [%{destinations: %{^key => %{"status" => "ok"}}}] = stored(stamp).artifacts
      end
    end

    test "each adopted directory's unit is checked against the row right before its delete: " <>
           "an adoption removed after the pass read it deletes nothing more",
         %{dir: dir, dir_id: dir_id} do
      row = KilnCMS.Test.BackupDestinations.destination!()
      key = "dest:" <> row.id
      retired = Ecto.UUID.generate()
      run!(@a, [key], :succeeded, %{dir_id: retired})
      run!(@f, [key], :succeeded, %{dir_id: retired})
      run!(@b, [key])
      run!(@c, [key])

      config = %{
        fake(key, %{"entries" => Enum.flat_map([@a, @f, @b, @c], &listed/1)})
        | id: row.id
      }

      # What the pass read when it started; the row no longer adopts it.
      read_at_start = [adoption(retired, [dir_id])]

      assert {:ok, %{deleted: deleted}} = prune(dir, config, adoptions: read_at_start)
      assert deleted == dump_and_sidecar(@b)
      assert deletes() == dump_and_sidecar(@b)

      # Adopted on the row too: both go.
      Backups.adopt_backup_directories!(row, %{adopt: [retired]},
        actor: BackupSchedules.platform_admin()
      )

      config = %{
        config
        | settings: Map.put(config.settings, "entries", Enum.flat_map([@a, @f, @c], &listed/1))
      }

      assert {:ok, %{deleted: deleted}} =
               prune(dir, config, adoptions: stored_adoptions(row))

      assert Enum.sort(deleted) == Enum.sort(dump_and_sidecar(@a) ++ dump_and_sidecar(@f))
    end

    test "a backup directory with no .kiln-dir-id, or a malformed one, deletes nothing", %{
      dir: dir,
      key: key
    } do
      run!(@a, [key])
      run!(@b, [key])
      config = fake(key, %{"entries" => listed(@a) ++ listed(@b)})

      File.write!(DirId.path(dir), "not an id\n")
      assert {:error, {:dir_id, :malformed_dir_id} = reason} = prune(dir, config)
      assert Retention.describe(reason) =~ "couldn't read the backup directory's id"

      File.rm!(DirId.path(dir))
      assert {:error, {:dir_id, :enoent}} = prune(dir, config)

      refute_received {:fake_destination, :list, _, _}
      assert deletes() == []
    end
  end

  describe "destination_plan/5" do
    test "with no owners, nothing is deleted", %{dir: dir, dir_id: dir_id, key: key} do
      run!(@a, [key])
      run!(@b, [key])
      {:ok, local} = Retention.scan(dir)

      inventory =
        Retention.destination_inventory(key, listed(@a) ++ listed(@b), local, @now)

      runs = Map.new([@a, @b], &{&1, stored(&1)})
      policy = Policy.legacy(14)

      for opts <- [[], [owners: nil], [owners: []]] do
        plan = Retention.destination_plan(inventory, runs, policy, @now, opts)
        assert plan.delete == []
        assert [%{stamp: @a}] = plan.unowned
      end

      assert %{delete: [%{stamp: @a}]} =
               Retention.destination_plan(inventory, runs, policy, @now, owners: [dir_id])
    end
  end

  describe "run_on_destination/3 on BACKUP_RCLONE_REMOTE_PRUNE" do
    setup %{dir: dir} do
      env_remote!("r2:kiln")
      prune_env!(true)
      {:ok, dir_id} = DirId.local(dir)
      env_key = Destination.env_key("r2:kiln")
      %{dir_id: dir_id, env_key: env_key}
    end

    test "deletes only what an in-app run of this backup directory sent there", %{
      dir: dir,
      dir_id: dir_id,
      env_key: env_key
    } do
      other_dir = "20200105-000000"
      no_dir = "20200108-000000"
      foreign = "20200110-000000"

      run!(@a, [env_key], :succeeded, %{dir_id: dir_id})
      # Cron's copy, recorded under the same key.
      imported!(@f, env_key)
      # An in-app run of another backup directory.
      run!(other_dir, [env_key], :succeeded, %{dir_id: Ecto.UUID.generate()})
      # An in-app run that recorded no directory.
      run!(no_dir, [env_key], :succeeded, %{dir_id: nil})
      run!(@b, [env_key], :succeeded, %{dir_id: dir_id})

      config =
        fake(env_key, %{
          "entries" => Enum.flat_map([@a, other_dir, no_dir, foreign, @f, @b], &listed/1)
        })

      assert {:ok, %{deleted: deleted, units: 1, unowned: unowned, stopped: nil}} =
               prune(dir, config)

      assert deleted == dump_and_sidecar(@a)
      assert deletes() == dump_and_sidecar(@a)

      assert Enum.map(unowned, & &1.stamp) |> Enum.sort() ==
               Enum.sort([other_dir, no_dir, foreign, @f])

      assert [%{destinations: %{^env_key => %{"status" => "pruned"}}}] = stored(@a).artifacts
      assert [%{destinations: %{^env_key => %{"status" => "ok"}}}] = stored(@f).artifacts
    end

    test "a backup directory with no .kiln-dir-id deletes nothing", %{
      dir: dir,
      dir_id: dir_id,
      env_key: env_key
    } do
      run!(@a, [env_key], :succeeded, %{dir_id: dir_id})
      run!(@b, [env_key], :succeeded, %{dir_id: dir_id})
      File.rm!(DirId.path(dir))

      config = fake(env_key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:error, {:dir_id, :enoent} = reason} = prune(dir, config)
      assert Retention.describe(reason) =~ "couldn't read the backup directory's id"
      refute_received {:fake_destination, :list, _, _}
    end

    test "a config resolved for another remote is not the env destination", %{dir: dir} do
      config = fake(Destination.env_key("r2:elsewhere"), %{})

      assert {:error, :not_prunable} = prune(dir, config)
      refute_received {:fake_destination, :list, _, _}
    end

    test "a plugin's stored destination, even a disabled one, blocks it; nothing is listed", %{
      dir: dir,
      dir_id: dir_id,
      env_key: env_key
    } do
      run!(@a, [env_key], :succeeded, %{dir_id: dir_id})
      run!(@b, [env_key], :succeeded, %{dir_id: dir_id})
      KilnCMS.Test.BackupDestinations.destination!(%{enabled: false})

      config = fake(env_key, %{"entries" => listed(@a) ++ listed(@b)})

      assert {:error, :destination_unknown = reason} = prune(dir, config)
      assert Retention.describe(reason) =~ "can't be told"
      refute_received {:fake_destination, :list, _, _}
      assert deletes() == []
    end

    test "an S3 destination blocks it", %{dir: dir, env_key: env_key} do
      KilnCMS.Test.BackupDestinations.destination!(%{
        kind: "s3",
        settings: %{"endpoint" => "https://s3.test", "region" => "auto", "bucket" => "kiln"},
        secrets: %{"access_key_id" => "AKIDTEST", "secret_access_key" => "s3-secret-test"}
      })

      assert {:error, :destination_s3 = reason} = prune(dir, fake(env_key, %{}))

      assert Retention.describe(reason) ==
               "an S3 backup destination can't be compared with BACKUP_RCLONE_REMOTE"

      refute_received {:fake_destination, :list, _, _}
    end

    @tag :tmp_dir
    test "a destination that overlaps it blocks it; one beside it doesn't", %{
      dir: dir,
      tmp_dir: tmp_dir
    } do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :local_destination_roots, [
          tmp_dir
        ])
      )

      site = Path.join(tmp_dir, "site")
      File.mkdir_p!(site)

      Backups.create_backup_destination!(
        %{name: "Disk", kind: "local", settings: %{"path" => site}},
        actor: BackupSchedules.platform_admin()
      )

      # A plain path is a local directory to rclone, compared as one.
      beside = Path.join(tmp_dir, "remote")
      env_remote!(beside)
      assert {:ok, %{deleted: []}} = prune(dir, fake(Destination.env_key(beside), %{}))
      assert_received {:fake_destination, :list, _, _}

      # The env remote moved over the stored destination since it was saved.
      env_remote!(tmp_dir)

      assert {:error, :destination_overlap} =
               prune(dir, fake(Destination.env_key(tmp_dir), %{}))

      refute_received {:fake_destination, :list, _, _}
    end
  end

  # -- the env destination's notice in the status (#2950) ----------------------

  describe "the env destination's retention notice" do
    setup %{dir: dir} do
      env_remote!("r2:kiln")
      {:ok, dir_id} = DirId.local(dir)

      KilnCMS.Backups.Notices.retention(
        {:env, Destination.env_key("r2:kiln"), "r2:kiln", dir},
        {:skipped, :destination_unknown}
      )

      %{dir_id: dir_id}
    end

    test "shows in the status while BACKUP_RCLONE_REMOTE_PRUNE is on", %{dir_id: dir_id} do
      prune_env!(true)
      key = Destination.env_key("r2:kiln")

      assert [
               %{
                 scope: {:destination, ^key},
                 label: "r2:kiln",
                 outcome: :skipped,
                 dir_id: ^dir_id
               }
             ] = Backups.status().retention
    end

    test "is hidden while it is off" do
      prune_env!(false)
      assert Backups.status().retention == []
    end

    test "is hidden when no live node has its backup directory", %{base: base} do
      prune_env!(true)
      # This node now writes to another directory, and no heartbeat names
      # the old one.
      other = Path.join(base, "elsewhere")
      File.mkdir_p!(other)
      DirId.local(other)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :dir, other)
      )

      assert Backups.status().retention == []
    end
  end

  # -- the shared rule (#2950) ----------------------------------------------

  describe "prune_blocker/3" do
    defp row(kind, settings), do: %{id: Ecto.UUID.generate(), kind: kind, settings: settings}

    defp stored_config(%{id: id, kind: kind, settings: settings}),
      do: %Config{id: id, key: "dest:" <> id, kind: kind, settings: settings}

    @env {:rclone, "r2", ["kiln"]}
    @s3 %{"endpoint" => "https://s3.test", "region" => "auto", "bucket" => "kiln"}

    test "the env destination: clear with no rows, or rows that can be told apart from it" do
      assert Retention.prune_blocker(:env, [], @env) == nil

      rows = [
        row("rclone", %{"remote_name" => "r2", "path" => "other"}),
        row("rclone", %{"remote_name" => "b2", "path" => "kiln"}),
        row("local", %{"path" => "/mnt/nas/kiln"})
      ]

      assert Retention.prune_blocker(:env, rows, @env) == nil
    end

    test "the env destination: blocked by any row it can't be told apart from" do
      assert Retention.prune_blocker(:env, [row("fake", %{})], @env) == :destination_unknown
      assert Retention.prune_blocker(:env, [row("s3", @s3)], @env) == :destination_s3

      inside = row("rclone", %{"remote_name" => "r2", "path" => "kiln/site"})
      assert Retention.prune_blocker(:env, [inside], @env) == :destination_overlap

      above = row("rclone", %{"remote_name" => "r2", "path" => ""})
      assert Retention.prune_blocker(:env, [above], @env) == :destination_overlap

      assert Retention.prune_blocker(:env, [], nil) == :not_prunable
    end

    test "a local env remote: a plain path is compared as a directory, an inline :local: " <>
           "backend by its name" do
      local = row("local", %{"path" => "/mnt/backups/kiln"})

      assert Retention.prune_blocker(:env, [local], Rclone.location("/mnt/backups")) ==
               :destination_overlap

      assert Retention.prune_blocker(:env, [local], Rclone.location(":local:/mnt/backups")) ==
               nil
    end

    test "a stored destination: clear, or why not" do
      own = row("rclone", %{"remote_name" => "r2", "path" => "site"})
      config = stored_config(own)

      assert Retention.prune_blocker(config, [own], nil) == nil
      assert Retention.prune_blocker(config, [own], @env) == nil

      assert Retention.prune_blocker(config, [own], {:rclone, "r2", []}) == :env_overlap

      inner = row("rclone", %{"remote_name" => "r2", "path" => "site/inner"})
      assert Retention.prune_blocker(config, [own, inner], nil) == :destination_overlap

      # A plugin's row overlaps nothing that can be told.
      assert Retention.prune_blocker(config, [own, row("fake", %{})], nil) == nil

      fake = row("fake", %{})
      assert Retention.prune_blocker(stored_config(fake), [fake], nil) == nil
      assert Retention.prune_blocker(stored_config(fake), [fake], @env) == :env_overlap_unknown

      s3 = row("s3", @s3)
      assert Retention.prune_blocker(stored_config(s3), [s3], @env) == :env_overlap_unknown
    end

    test "a bucket of the same name on another host blocks both rows as a possible overlap " <>
           "(#3088)" do
      global =
        row("s3", %{@s3 | "endpoint" => "https://s3.amazonaws.com"} |> Map.put("prefix", "site"))

      regional =
        row(
          "s3",
          %{@s3 | "endpoint" => "https://s3.us-east-1.amazonaws.com"}
          |> Map.put("prefix", "site/a")
        )

      rows = [global, regional]

      for row <- rows do
        assert Retention.prune_blocker(stored_config(row), rows, nil) ==
                 :destination_overlap_possible
      end

      assert Retention.describe(:destination_overlap_possible) ==
               "another S3 backup destination uses a bucket of the same name; the app can't " <>
                 "tell whether it is the same store"

      # An exact overlap is still named as one.
      same_host = row("s3", Map.put(@s3, "prefix", "site"))
      inner = row("s3", Map.put(@s3, "prefix", "site/inner"))

      assert Retention.prune_blocker(stored_config(same_host), [same_host, inner, global], nil) ==
               :destination_overlap

      # A different bucket, or prefixes side by side, block nothing.
      other_bucket = row("s3", %{@s3 | "bucket" => "else"} |> Map.put("prefix", "site"))
      beside = row("s3", %{@s3 | "endpoint" => "https://other.test"} |> Map.put("prefix", "b"))

      assert Retention.prune_blocker(stored_config(global), [global, other_bucket, beside], nil) ==
               nil
    end

    test "a stored destination whose adapter can't list and delete" do
      Application.put_env(:kiln_cms, KilnCMS.Backups.Destination,
        extra_adapters: [KilnCMS.Test.BackupDestinations.Fake, Bare]
      )

      bare = row("bare_test", %{})
      assert Retention.prune_blocker(stored_config(bare), [bare], nil) == :unsupported
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

    defp prune_env!(on?) do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups), :rclone_remote_prune, on?)
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

    # #3088: one bucket name reached through two hosts. The pass is refused
    # before anything is listed, with the reason the notice and log quote.
    test "an S3 destination whose bucket another S3 destination names on another host is skipped",
         %{dir: dir} do
      s3 = fn endpoint ->
        Backups.create_backup_destination!(
          %{
            name: "Bucket #{System.unique_integer([:positive])}",
            kind: "s3",
            settings: %{
              "endpoint" => endpoint,
              "region" => "us-east-1",
              "bucket" => "kiln",
              "prefix" => "site"
            },
            secrets: %{"access_key_id" => "AKIDTEST", "secret_access_key" => "s3-secret-test"}
          },
          actor: BackupSchedules.platform_admin()
        )
      end

      global = s3.("https://s3.amazonaws.com")
      _regional = s3.("https://s3.us-east-1.amazonaws.com")

      {:ok, config} = KilnCMS.Backups.DestinationConfig.to_config(global)
      assert {:error, :destination_overlap_possible = reason} = prune(dir, config)

      assert Retention.describe(reason) =~ "same name"
    end
  end

  # -- two SFTP servers told apart by their host keys (#3200) ------------------

  describe "prune_blocker/3: SFTP rows told apart by their trusted host keys (#3200)" do
    @ed "ssh-ed25519"
    @fp_a "SHA256:" <> String.duplicate("A", 43)
    @fp_b "SHA256:" <> String.duplicate("B", 43)

    defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

    # A row on `host` at `path` trusting `key` (`{type, fingerprint}` or
    # nil) since `:trusted` seconds ago, whose last Test (`:tested`
    # seconds ago, or nil for none) passed unless `ok: false`.
    defp sftp_row(host, path, key, opts \\ []) do
      host_key =
        with {type, fingerprint} <- key do
          %{
            "algorithm" => type,
            "fingerprint" => fingerprint,
            "trusted_at" => DateTime.to_iso8601(ago(Keyword.get(opts, :trusted, 3600)))
          }
        end

      tested = Keyword.get(opts, :tested, 60)

      %{
        id: Ecto.UUID.generate(),
        kind: "sftp",
        settings: %{
          "host" => host,
          "port" => 22,
          "username" => Keyword.get(opts, :user, "kiln"),
          "path" => path
        },
        host_key: host_key,
        last_test_ok: if(tested, do: Keyword.get(opts, :ok, true)),
        last_tested_at: if(tested, do: ago(tested))
      }
    end

    defp blockers(rows),
      do: Enum.map(rows, &Retention.prune_blocker(stored_config(&1), rows, nil))

    @blocked [:destination_overlap_possible_sftp, :destination_overlap_possible_sftp]

    test "different trusted servers, each tested since both were trusted, both prune" do
      rows = [
        sftp_row("nas-a.test", "/backups", {@ed, @fp_a}),
        sftp_row("nas-b.test", "/backups", {@ed, @fp_b})
      ]

      assert blockers(rows) == [nil, nil]

      # Nested, not equal, too.
      [a, b] = rows
      inner = %{b | settings: %{b.settings | "path" => "/backups/site"}}
      assert blockers([a, inner]) == [nil, nil]
    end

    test "one server by name and by IP (the same fingerprint) stays blocked" do
      rows = [
        sftp_row("nas.test", "/backups", {@ed, @fp_a}),
        sftp_row("10.0.0.5", "/backups", {@ed, @fp_a})
      ]

      assert blockers(rows) == @blocked
    end

    test "a key not yet trusted on either side keeps the broad rule" do
      assert blockers([
               sftp_row("nas-a.test", "/backups", {@ed, @fp_a}),
               sftp_row("nas-b.test", "/backups", nil)
             ]) == @blocked

      assert blockers([
               sftp_row("nas-a.test", "/backups", nil),
               sftp_row("nas-b.test", "/backups", nil)
             ]) == @blocked
    end

    test "keys of different types stay blocked: one server holds an ed25519 and an RSA key" do
      assert blockers([
               sftp_row("nas.test", "/backups", {@ed, @fp_a}),
               sftp_row("10.0.0.5", "/backups", {"ssh-rsa", @fp_b})
             ]) == @blocked
    end

    test "a disabled row on a reinstalled server, never tested since, stays blocked" do
      # A trusted K1 and was disabled; it last passed a Test before the NAS
      # was reinstalled (K2). B was added on the same NAS by IP, trusting K2,
      # and tested. A has not connected since B's trust.
      a = sftp_row("nas.lan", "/backups", {@ed, @fp_a}, trusted: 86_400 * 30, tested: 86_400 * 20)
      b = sftp_row("192.168.1.10", "/backups/kiln", {@ed, @fp_b}, trusted: 3600, tested: 60)
      a = Map.put(a, :enabled, false)

      assert blockers([a, b]) == @blocked

      # Never tested at all: blocked too.
      assert blockers([%{a | last_test_ok: nil, last_tested_at: nil}, b]) == @blocked
    end

    test "a rotation: A trusted again after B's last Test, blocked" do
      # One NAS rotated its key; A was re-trusted with the new one (and
      # passed), B still holds the old and was last tested before that.
      a = sftp_row("nas.test", "/backups", {@ed, @fp_a}, trusted: 600, tested: 60)
      b = sftp_row("10.0.0.5", "/backups", {@ed, @fp_b}, trusted: 86_400, tested: 3600)

      assert blockers([a, b]) == @blocked
    end

    test "a failed last Test, even after both trusts, keeps the pair blocked" do
      a = sftp_row("nas-a.test", "/backups", {@ed, @fp_a})
      b = sftp_row("nas-b.test", "/backups", {@ed, @fp_b}, ok: false)

      assert blockers([a, b]) == @blocked
    end

    test "a Test before its own trust doesn't count" do
      a = sftp_row("nas-a.test", "/backups", {@ed, @fp_a}, trusted: 600, tested: 900)
      b = sftp_row("nas-b.test", "/backups", {@ed, @fp_b}, trusted: 3600, tested: 60)

      assert blockers([a, b]) == @blocked
    end

    test "an unreadable trust time proves nothing" do
      [a, b] = [
        sftp_row("nas-a.test", "/backups", {@ed, @fp_a}),
        sftp_row("nas-b.test", "/backups", {@ed, @fp_b})
      ]

      b = %{b | host_key: %{b.host_key | "trusted_at" => "yesterday"}}
      assert blockers([a, b]) == @blocked
    end

    test "a subject with no row of its own in rows is never proven" do
      a = sftp_row("nas-a.test", "/backups", {@ed, @fp_a})
      b = sftp_row("nas-b.test", "/backups", {@ed, @fp_b})

      assert Retention.prune_blocker(stored_config(a), [b], nil) ==
               :destination_overlap_possible_sftp

      assert Retention.prune_blocker(stored_config(a), [a, b], nil) == nil
    end

    test "the same host, port and login, nested, is still an exact overlap" do
      assert blockers([
               sftp_row("nas.test", "/backups", {@ed, @fp_a}),
               sftp_row("nas.test", "/backups/site", {@ed, @fp_b})
             ]) == [:destination_overlap, :destination_overlap]
    end

    test "the reason's text says how to clear it" do
      assert Retention.describe(:destination_overlap_possible_sftp) =~
               "each has passed a Test since the later of the two was trusted"
    end
  end

  # -- whether a Test would clear the SFTP blocker (#3428) ---------------------

  describe "cleared_by_test?/3 (#3428)" do
    # `sftp_row/4`, `blockers/1`, `@ed`, `@fp_a`, `@fp_b` and `@blocked` are
    # the #3200 block's above.
    @fp_c "SHA256:" <> String.duplicate("C", 43)

    defp cleared(rows),
      do: Enum.map(rows, &Retention.cleared_by_test?(stored_config(&1), rows, nil))

    # A trusted after B's last Test: only the Tests are missing.
    defp untested_pair do
      [
        sftp_row("nas-a.test", "/backups", {@ed, @fp_a}, trusted: 600, tested: 900),
        sftp_row("nas-b.test", "/backups", {@ed, @fp_b}, trusted: 3600, tested: 1800)
      ]
    end

    test "trusted keys of one type that differ, not tested since: a Test would clear both" do
      rows = untested_pair()

      assert blockers(rows) == @blocked
      assert cleared(rows) == [true, true]

      # Never tested at all, the same.
      untested = Enum.map(rows, &%{&1 | last_test_ok: nil, last_tested_at: nil})
      assert cleared(untested) == [true, true]
    end

    test "after both Tests pass the pair prunes, and no hint is left" do
      [a, b] = untested_pair()
      now = DateTime.utc_now()

      rows = [
        %{a | last_test_ok: true, last_tested_at: now},
        %{b | last_test_ok: true, last_tested_at: now}
      ]

      assert blockers(rows) == [nil, nil]
      assert cleared(rows) == [false, false]
    end

    test "one fingerprint on both: no Test tells them apart" do
      rows = [
        sftp_row("nas.test", "/backups", {@ed, @fp_a}, tested: nil),
        sftp_row("10.0.0.5", "/backups", {@ed, @fp_a}, tested: nil)
      ]

      assert blockers(rows) == @blocked
      assert cleared(rows) == [false, false]
    end

    test "a key not yet trusted: false" do
      rows = [
        sftp_row("nas-a.test", "/backups", {@ed, @fp_a}, tested: nil),
        sftp_row("nas-b.test", "/backups", nil, tested: nil)
      ]

      assert blockers(rows) == @blocked
      assert cleared(rows) == [false, false]
    end

    test "keys of different types: false" do
      rows = [
        sftp_row("nas.test", "/backups", {@ed, @fp_a}, tested: nil),
        sftp_row("10.0.0.5", "/backups", {"ssh-rsa", @fp_b}, tested: nil)
      ]

      assert blockers(rows) == @blocked
      assert cleared(rows) == [false, false]
    end

    test "an unreadable trust time: false" do
      [a, b] = untested_pair()
      b = %{b | host_key: %{b.host_key | "trusted_at" => "yesterday"}}

      assert cleared([a, b]) == [false, false]
    end

    test "three rows: one partner a Test would clear and one it can't, false" do
      # B differs from A and only needs the Tests; C shares A's fingerprint,
      # which no Test changes. A stays blocked whatever is tested.
      [a, b] = untested_pair()
      c = sftp_row("10.0.0.5", "/backups", {@ed, @fp_a}, trusted: 600, tested: nil)
      rows = [a, b, c]

      assert blockers(rows) == [
               :destination_overlap_possible_sftp,
               :destination_overlap_possible_sftp,
               :destination_overlap_possible_sftp
             ]

      [cleared_a, _b, cleared_c] = cleared(rows)
      refute cleared_a
      refute cleared_c
    end

    test "three rows all told apart by key, not tested since: true for each" do
      [a, b] = untested_pair()
      c = sftp_row("nas-c.test", "/backups", {@ed, @fp_c}, trusted: 600, tested: nil)

      assert cleared([a, b, c]) == [true, true, true]
    end

    test "an exact overlap or any other blocker: false" do
      rows = [
        sftp_row("nas.test", "/backups", {@ed, @fp_a}, trusted: 600, tested: nil),
        sftp_row("nas.test", "/backups/site", {@ed, @fp_b}, trusted: 600, tested: nil)
      ]

      assert blockers(rows) == [:destination_overlap, :destination_overlap]
      assert cleared(rows) == [false, false]

      [a, b] = untested_pair()
      env = {:rclone, "r2", ["kiln"]}
      refute Retention.cleared_by_test?(stored_config(a), [a, b], env)
      refute Retention.cleared_by_test?(:env, [a, b], env)
    end

    test "prune_blocker/3 is unchanged by it: the subject with no row is never cleared" do
      [a, b] = untested_pair()

      assert Retention.prune_blocker(stored_config(a), [b], nil) ==
               :destination_overlap_possible_sftp

      refute Retention.cleared_by_test?(stored_config(a), [b], nil)
    end
  end

  describe "run_on_destination/3 on two SFTP servers at the same path (#3200)" do
    @describetag :tmp_dir

    setup do
      previous = Application.get_env(:kiln_cms, Sftp, [])
      Application.put_env(:kiln_cms, Sftp, Keyword.put(previous, :private_hosts, ["127.0.0.1"]))
      servers = [SftpServer.start!(), SftpServer.start!()]

      on_exit(fn ->
        Application.put_env(:kiln_cms, Sftp, previous)
        # A test may have stopped one already, to fail its Test.
        for server <- servers do
          try do
            SftpServer.stop(server)
          catch
            :exit, _already_stopped -> :ok
          end
        end
      end)

      %{servers: servers}
    end

    # A stored SFTP destination at `/backups` on `server`, trusting `key`.
    defp sftp_destination!(server, {type, fingerprint}) do
      admin = BackupSchedules.platform_admin()

      row =
        Backups.create_backup_destination!(
          %{
            name: "NAS #{System.unique_integer([:positive])}",
            kind: "sftp",
            enabled: false,
            settings: %{
              "host" => "127.0.0.1",
              "port" => server.port,
              "username" => SftpServer.user(),
              "path" => "/backups"
            },
            secrets: %{"password" => SftpServer.password()}
          },
          actor: admin
        )

      {:ok, row} =
        Backups.trust_backup_destination_host_key(
          row,
          type,
          fingerprint,
          :scanned,
          %{previous_fingerprint: nil, scanned_for: Sftp.Target.server(row.settings)},
          actor: admin
        )

      row
    end

    defp test!(row),
      do: Backups.test_destination(row.id, actor: BackupSchedules.platform_admin())

    defp config!(row) do
      {:ok, config} = DestinationConfig.to_config(row)
      %{config | secrets: %{"password" => SftpServer.password()}}
    end

    # The units of `stamps`, 400 days old, in `server`'s `/backups/db`.
    defp seed_sftp(server, stamps) do
      db = Path.join([server.root, "backups", "db"])
      File.mkdir_p!(db)
      old = @now - 400 * @day

      for stamp <- stamps, name <- dump_and_sidecar(stamp) do
        path = Path.join(db, name)
        File.write!(path, "x")
        File.touch!(path, old)
      end
    end

    defp remaining(server),
      do: Path.join([server.root, "backups", "db"]) |> File.ls!() |> Enum.sort()

    test "different trusted servers, each tested after both trusts, both prune", %{
      dir: dir,
      servers: [one, two]
    } do
      a = sftp_destination!(one, {one.type, one.fingerprint})
      b = sftp_destination!(two, {two.type, two.fingerprint})
      assert one.type == two.type
      refute one.fingerprint == two.fingerprint

      # Not tested yet: blocked.
      assert {:error, :destination_overlap_possible_sftp} = prune(dir, config!(a))

      assert {:ok, %{last_test_ok: true}} = test!(a)
      assert {:ok, %{last_test_ok: true}} = test!(b)

      run!(@a, ["dest:" <> a.id, "dest:" <> b.id])
      run!(@b, ["dest:" <> a.id, "dest:" <> b.id])
      run!(@c, ["dest:" <> a.id, "dest:" <> b.id], :failed)

      for {server, row} <- [{one, a}, {two, b}] do
        seed_sftp(server, [@a, @b, @c])
        assert {:ok, %{deleted: deleted}} = prune(dir, config!(row))
        assert Enum.sort(deleted) == Enum.sort(dump_and_sidecar(@a))
        assert remaining(server) == Enum.sort(dump_and_sidecar(@b) ++ dump_and_sidecar(@c))
      end
    end

    test "one key trusted for both (one server under two ports) is skipped", %{
      dir: dir,
      servers: [one, two]
    } do
      a = sftp_destination!(one, {one.type, one.fingerprint})
      b = sftp_destination!(two, {one.type, one.fingerprint})
      assert {:ok, %{last_test_ok: true}} = test!(a)
      # B's server offers another key than the one B trusts: its Test fails.
      assert {:ok, %{last_test_ok: false}} = test!(b)

      run!(@a, ["dest:" <> a.id, "dest:" <> b.id])
      run!(@b, ["dest:" <> a.id, "dest:" <> b.id])
      seed_sftp(one, [@a, @b])

      for row <- [a, b] do
        assert {:error, :destination_overlap_possible_sftp} = prune(dir, config!(row))
      end

      assert remaining(one) == Enum.sort(dump_and_sidecar(@a) ++ dump_and_sidecar(@b))
    end

    test "a failed Test after both trusts skips both", %{dir: dir, servers: [one, two]} do
      a = sftp_destination!(one, {one.type, one.fingerprint})
      b = sftp_destination!(two, {two.type, two.fingerprint})
      assert {:ok, %{last_test_ok: true}} = test!(a)
      assert {:ok, %{last_test_ok: true}} = test!(b)

      # B's server goes away: its next Test fails.
      SftpServer.stop(two)
      assert {:ok, %{last_test_ok: false}} = test!(b)

      run!(@a, ["dest:" <> a.id, "dest:" <> b.id])
      run!(@b, ["dest:" <> a.id, "dest:" <> b.id])
      seed_sftp(one, [@a, @b])

      assert {:error, :destination_overlap_possible_sftp} = prune(dir, config!(a))
      assert remaining(one) == Enum.sort(dump_and_sidecar(@a) ++ dump_and_sidecar(@b))
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

    # A backup chain whose start step runs, then `between`, then the rest:
    # what a change made while a backup runs meets.
    defp run_with(between) do
      BackupChain.listen(fn ->
        {:ok, %{status: :started, chain: chain}} =
          Backups.request([trigger: "manual"], Backups.system())

        BackupChain.drain(with_recursion: false)
        assert [%{status: :pending}] = current_run().destinations
        between.()
        BackupChain.drain()
        BackupChain.settled(chain)
      end)
    end

    @tag :tmp_dir
    test "keeps another backup directory's backups, and says so", %{tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir)
      key = "dest:" <> row.id
      run!(@a, [key], :succeeded, %{dir_id: Ecto.UUID.generate()})
      run!(@b, [key])
      seed(path, [@a, @b])

      assert :ok = BackupChain.run()
      run = current_run()

      assert present?(path, @a)
      assert %{status: :ok, pruned: 0} = Enum.find(run.destinations, &(&1.key == key))

      messages = Enum.map(run.log, & &1.message)

      assert ("Retention on Disk kept 1 backup(s) sent by another backup directory " <>
                "(see Destinations)") in messages

      refute Enum.any?(messages, &(&1 =~ "Retention on Disk left"))
    end

    @tag :tmp_dir
    test "an adoption made while a backup runs is obeyed by its pass", %{tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir)
      key = "dest:" <> row.id
      retired = Ecto.UUID.generate()
      run!(@a, [key], :succeeded, %{dir_id: retired})
      run!(@b, [key])
      seed(path, [@a, @b])

      assert :ok =
               run_with(fn ->
                 Backups.adopt_backup_directories!(row, %{adopt: [retired]},
                   actor: BackupSchedules.platform_admin()
                 )
               end)

      refute present?(path, @a)
      assert present?(path, @b)
      assert %{pruned: 1} = Enum.find(current_run().destinations, &(&1.key == key))
    end

    @tag :tmp_dir
    test "an adoption removed while a backup runs is obeyed by its pass", %{tmp_dir: tmp_dir} do
      {row, path} = local!(tmp_dir)
      key = "dest:" <> row.id
      retired = Ecto.UUID.generate()
      admin = BackupSchedules.platform_admin()
      run!(@a, [key], :succeeded, %{dir_id: retired})
      run!(@b, [key])
      seed(path, [@a, @b])

      row = Backups.adopt_backup_directories!(row, %{adopt: [retired]}, actor: admin)

      assert :ok =
               run_with(fn ->
                 Backups.adopt_backup_directories!(row, %{release: [retired]}, actor: admin)
               end)

      assert present?(path, @a)
      assert %{pruned: 0} = Enum.find(current_run().destinations, &(&1.key == key))
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
    # `BACKUP_RCLONE_REMOTE` set to `r2:kiln`. Its `lsjson` of `db/` lists
    # the dumps and sidecars of `stamps`, 400 days old (#2950).
    defp env_rclone!(base, stamps \\ []) do
      bin = Path.join(base, "bin")
      log = Path.join(base, "rclone.log")
      listing = Path.join(base, "db.json")
      File.mkdir_p!(bin)

      modified =
        (System.os_time(:second) - 400 * @day) |> DateTime.from_unix!() |> DateTime.to_iso8601()

      File.write!(
        listing,
        Jason.encode!(
          for stamp <- stamps, name <- dump_and_sidecar(stamp) do
            %{"Name" => name, "Size" => 10, "ModTime" => modified, "IsDir" => false}
          end
        )
      )

      File.write!(Path.join(bin, "rclone"), """
      #!/bin/sh
      echo "$*" >> "#{log}"
      case "$1 $3" in
        "lsjson "*/db) cat "#{listing}" ;;
        "lsjson "*) echo "[]" ;;
      esac
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

    test "with BACKUP_RCLONE_REMOTE_PRUNE off, the env destination is never listed or pruned, " <>
           "and an old notice there is cleared",
         %{base: base, dir: dir} do
      log = env_rclone!(base, [@a, @b])
      {:ok, dir_id} = DirId.local(dir)

      run!(@a, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})
      run!(@b, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})

      Backups.report_backup_notice!(
        %{
          kind: :retention,
          scope: "rclone:r2:kiln",
          outcome: :skipped,
          reason: "x",
          at: DateTime.utc_now()
        },
        actor: Backups.system()
      )

      assert :ok = BackupChain.run()

      calls = log |> File.read!() |> String.split("\n", trim: true)
      assert calls != []
      assert Enum.all?(calls, &String.starts_with?(&1, "copy "))
      assert [%{destinations: %{"rclone:r2:kiln" => %{"status" => "ok"}}}] = stored(@a).artifacts
      assert Backups.list_backup_notices!(actor: Backups.system()) == []
    end

    test "with BACKUP_RCLONE_REMOTE_PRUNE on, the env destination is pruned of what this " <>
           "backup directory's in-app runs sent there, and nothing else",
         %{base: base, dir: dir} do
      log = env_rclone!(base, [@a, @f, @b])
      prune_env!(true)
      {:ok, dir_id} = DirId.local(dir)

      run!(@a, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})
      imported!(@f, "rclone:r2:kiln")
      run!(@b, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})

      assert :ok = BackupChain.run()
      run = current_run()

      deleted =
        log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "deletefile "))

      assert deleted == Enum.map(dump_and_sidecar(@a), &"deletefile r2:kiln/db/#{&1} -q")

      assert %{status: :ok, pruned: 1} =
               Enum.find(run.destinations, &(&1.key == "rclone:r2:kiln"))

      messages = Enum.map(run.log, & &1.message)
      assert "Retention on r2:kiln removed 2 file(s) from 1 backup(s)" in messages

      assert Enum.any?(
               messages,
               &(&1 =~ "Retention on r2:kiln left 1 old backup(s) no in-app backup of this " and
                   &1 =~ @f)
             )

      assert [%{destinations: %{"rclone:r2:kiln" => %{"status" => "pruned"}}}] =
               stored(@a).artifacts

      assert [%{destinations: %{"rclone:r2:kiln" => %{"status" => "ok"}}}] = stored(@f).artifacts
      assert Backups.status().retention == []
    end

    test "with BACKUP_RCLONE_REMOTE_PRUNE on, a stored destination it can't be told apart " <>
           "from skips it, with a notice, and nothing is listed",
         %{base: base, dir: dir} do
      log = env_rclone!(base, [@a, @b])
      prune_env!(true)
      {:ok, dir_id} = DirId.local(dir)
      run!(@a, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})
      run!(@b, ["rclone:r2:kiln"], :succeeded, %{dir_id: dir_id})

      # Disabled: never sent to, but its files may still be there.
      KilnCMS.Test.BackupDestinations.destination!(%{enabled: false})

      assert :ok = BackupChain.run()
      run = current_run()

      calls = log |> File.read!() |> String.split("\n", trim: true)
      assert Enum.all?(calls, &String.starts_with?(&1, "copy "))

      assert %{status: :ok, pruned: 0} =
               Enum.find(run.destinations, &(&1.key == "rclone:r2:kiln"))

      assert Enum.any?(
               run.log,
               &(&1.level == :error and
                   &1.message =~ "Retention on r2:kiln skipped: a stored backup destination's" and
                   &1.message =~ "nothing was deleted")
             )

      assert [%{scope: {:destination, "rclone:r2:kiln"}, outcome: :skipped}] =
               Backups.status().retention
    end
  end
end
