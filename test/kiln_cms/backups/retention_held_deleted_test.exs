defmodule KilnCMS.Backups.RetentionHeldDeletedTest.NoImport do
  @moduledoc false
  # The `:importer` seam: imports nothing, so a backup on disk stays
  # unrecorded (no Run row), as one whose import keeps failing is.
  def run(_dir), do: {:ok, %{imported: 0, pending: 0, skipped: 0, failed: 0, deferred: 0}}
end

defmodule KilnCMS.Backups.RetentionHeldDeletedTest do
  @moduledoc """
  A held backup deleted outside the app (#2931): at each hold sync, a unit a
  `.hold` named that has nothing left but its sidecar, or nothing at all, and
  that the app did not prune itself, is logged, counted and reported once,
  when its stale `.hold` is removed. A host whose `scripts/backup.sh`
  predates the hold markers is what does that.

  `async: false`: points `:kiln_cms, KilnCMS.Backups` at a temp directory
  (`Application.put_env` is VM-global).
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupSchedules, only: [schedule!: 1]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Chain, Recorder, Retention}

  @moduletag :capture_log

  @day 24 * 3600
  @older "20200101-000000"
  @old "20260701-000000"
  @new "20260801-000000"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_held_del_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, keep_days: 14)
    )

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:kiln_cms, :backups, :hold, :deleted_outside]
      ])

    on_exit(fn ->
      :telemetry.detach(ref)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    test_pid = self()
    notify = fn dir, units -> send(test_pid, {:notified, dir, units}) end

    %{dir: dir, ref: ref, notify: notify}
  end

  # A file `days` days old under `sub`.
  defp put(dir, sub, name, days, content \\ "x") do
    path = Path.join([dir, sub, name])
    File.write!(path, content)
    File.touch!(path, System.os_time(:second) - round(days * @day))
    path
  end

  defp dump(dir, stamp, days) do
    put(dir, "db", "kiln-db-#{stamp}.dump", days)
    put(dir, "db", Artifact.sidecar_name(:db, stamp), days)
  end

  # A complete backup of both kinds, a day old.
  defp newest(dir) do
    dump(dir, @new, 1)
    put(dir, "media", "kiln-media-#{@new}.tar.gz", 1)
  end

  defp hold!(dir, sub, stamp), do: put(dir, sub, Artifact.hold_name(stamp), 1, "")

  defp hold?(dir, sub, stamp), do: File.exists?(Path.join([dir, sub, Artifact.hold_name(stamp)]))

  defp rm!(dir, sub, name), do: File.rm!(Path.join([dir, sub, name]))

  defp sync(ctx), do: Retention.sync_last_good(ctx.dir, notify: ctx.notify)

  # A schedule keeping two database backups holds @old and @new.
  defp held_old!(ctx) do
    newest(ctx.dir)
    dump(ctx.dir, @old, 3)
    schedule!(%{keep_count: 2})

    assert {:ok, _} = sync(ctx)
    assert hold?(ctx.dir, "db", @old)
    refute_received {:notified, _, _}
  end

  describe "a held unit deleted behind the app's back" do
    test "is logged, counted and reported once, and its hold goes", %{ref: ref} = ctx do
      held_old!(ctx)
      rm!(ctx.dir, "db", "kiln-db-#{@old}.dump")
      rm!(ctx.dir, "db", Artifact.sidecar_name(:db, @old))

      log = capture_log([level: :warning], fn -> assert {:ok, _} = sync(ctx) end)

      assert log =~
               "1 backup(s) a schedule keeps were deleted outside the app although their " <>
                 ".hold markers kept them: db backup #{@old}."

      assert log =~ "scripts/backup.sh is probably older than this release"

      assert_received {[:kiln_cms, :backups, :hold, :deleted_outside], ^ref, %{count: 1},
                       %{scope: :local, units: [%{stamp: @old, kind: :db}]}}

      dir = ctx.dir
      assert_received {:notified, ^dir, [%{stamp: @old, kind: :db}]}
      refute hold?(dir, "db", @old)
      assert hold?(dir, "db", @new)

      # The next sync has nothing to say.
      assert {:ok, _} = sync(ctx)
      refute_received {:notified, _, _}
      refute_received {[:kiln_cms, :backups, :hold, :deleted_outside], _, _, _}
    end

    test "a script that leaves the sidecar (backup.sh up to 1.8) is reported", ctx do
      held_old!(ctx)
      # `find … -name 'kiln-db-*.dump' -delete`: the .sha256 stays.
      rm!(ctx.dir, "db", "kiln-db-#{@old}.dump")

      assert {:ok, _} = sync(ctx)

      assert_received {:notified, _, [%{stamp: @old, kind: :db}]}
      refute hold?(ctx.dir, "db", @old)
      assert File.exists?(Path.join([ctx.dir, "db", Artifact.sidecar_name(:db, @old)]))
    end

    test "one a schedule's keep days held is reported, though its sidecar is still young",
         ctx do
      newest(ctx.dir)
      # Cron-made and 20 days old: the schedule's 30 days raise the floor.
      dump(ctx.dir, @old, 20)
      schedule!(%{keep_days: 30})

      assert {:ok, _} = sync(ctx)
      assert hold?(ctx.dir, "db", @old)

      rm!(ctx.dir, "db", "kiln-db-#{@old}.dump")
      assert {:ok, _} = sync(ctx)

      assert_received {:notified, _, [%{stamp: @old, kind: :db}]}
      refute hold?(ctx.dir, "db", @old)
    end

    test "a backup no run records is reported", ctx do
      newest(ctx.dir)
      hold!(ctx.dir, "db", @older)

      assert {:ok, _} = sync(ctx)

      assert_received {:notified, _, [%{stamp: @older, kind: :db}]}
      assert Backups.get_run_by_stamp!(@older, actor: Backups.system()) == nil
    end

    test "a media set whose parts are all gone is reported once, as media", ctx do
      newest(ctx.dir)
      dump(ctx.dir, @old, 3)
      put(ctx.dir, "media", Artifact.part_name(@old, 1), 3)
      put(ctx.dir, "media", Artifact.part_name(@old, 2), 3)
      put(ctx.dir, "media", Artifact.sidecar_name(:media, @old), 3)
      hold!(ctx.dir, "media", @old)
      rm!(ctx.dir, "media", Artifact.part_name(@old, 1))
      rm!(ctx.dir, "media", Artifact.part_name(@old, 2))

      assert {:ok, _} = sync(ctx)

      assert_received {:notified, _, [%{stamp: @old, kind: :media}]}
      refute_received {:notified, _, _}
    end

    test "names ten in the log and counts them all", %{ref: ref} = ctx do
      newest(ctx.dir)
      stamps = for n <- 10..21, do: "20200101-0000#{n}"
      for stamp <- stamps, do: hold!(ctx.dir, "db", stamp)

      log = capture_log([level: :warning], fn -> assert {:ok, _} = sync(ctx) end)

      assert log =~ "12 backup(s) a schedule keeps were deleted outside the app"
      assert log =~ "db backup 20200101-000019 and 2 more."
      refute log =~ "20200101-000020"

      assert_received {[:kiln_cms, :backups, :hold, :deleted_outside], ^ref, %{count: 12}, _}
      assert_received {:notified, _, units}
      assert Enum.map(units, & &1.stamp) == stamps
    end
  end

  describe "not reported" do
    test "a unit the app pruned itself, though it stopped before the sidecar", ctx do
      held_old!(ctx)
      rm!(ctx.dir, "db", "kiln-db-#{@old}.dump")
      Recorder.mark_pruned(["kiln-db-#{@old}.dump"])

      assert {:ok, _} = sync(ctx)

      refute_received {:notified, _, _}
      refute hold?(ctx.dir, "db", @old)
    end

    test "a unit still there, whose hold went stale", ctx do
      newest(ctx.dir)
      dump(ctx.dir, @old, 3)
      hold!(ctx.dir, "db", @old)

      assert {:ok, _} = sync(ctx)

      refute_received {:notified, _, _}
      refute hold?(ctx.dir, "db", @old)
    end

    test "while the Run read fails; the hold stays and the next sync reports it", ctx do
      held_old!(ctx)
      rm!(ctx.dir, "db", "kiln-db-#{@old}.dump")
      rm!(ctx.dir, "db", Artifact.sidecar_name(:db, @old))

      assert {:error, {:read_runs, _}} =
               Backups.with_actor(nil, fn ->
                 Retention.sync_last_good(ctx.dir, notify: ctx.notify, import: false)
               end)

      refute_received {:notified, _, _}
      assert hold?(ctx.dir, "db", @old)

      assert {:ok, _} = sync(ctx)
      assert_received {:notified, _, [%{stamp: @old, kind: :db}]}
    end

    test "a hold that can't be removed (a directory), at any sync", ctx do
      newest(ctx.dir)
      File.mkdir_p!(Path.join([ctx.dir, "db", Artifact.hold_name(@older)]))

      assert {:ok, _} = sync(ctx)
      assert {:ok, _} = sync(ctx)

      refute_received {:notified, _, _}
      refute_received {[:kiln_cms, :backups, :hold, :deleted_outside], _, _, _}
      assert File.dir?(Path.join([ctx.dir, "db", Artifact.hold_name(@older)]))
    end
  end

  # #3004: a stale hold the sync can't remove keeps its unit for that pass.
  describe "a stale hold that can't be removed" do
    setup ctx do
      config = Application.get_env(:kiln_cms, KilnCMS.Backups)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        Keyword.put(config, :importer, KilnCMS.Backups.RetentionHeldDeletedTest.NoImport)
      )

      newest(ctx.dir)
      # Expired and unrecorded: the plan deletes it.
      dump(ctx.dir, @old, 400)
      :ok
    end

    test "keeps an unrecorded unit, says so, and it is never reported deleted outside",
         ctx do
      stuck = Path.join([ctx.dir, "db", Artifact.hold_name(@old)])
      File.mkdir_p!(stuck)

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{deleted: deleted, stopped: nil, kept: kept}} =
                   Retention.run(ctx.dir, notify: ctx.notify)

          refute "kiln-db-#{@old}.dump" in deleted
          assert kept == [%{stamp: @old, kind: :db, reason: {:not_regular, :directory}}]
        end)

      assert log =~
               "Retention kept db backup #{@old}: its stale hold marker " <>
                 "db/kiln-#{@old}.hold couldn't be removed (a directory, not a regular file)"

      assert File.exists?(Path.join([ctx.dir, "db", "kiln-db-#{@old}.dump"]))
      assert Backups.get_run_by_stamp!(@old, actor: Backups.system()) == nil

      kept = [%{stamp: @old, kind: :db, reason: {:not_regular, :directory}}]

      assert Retention.describe({:stale_holds, kept}) ==
               "a stale hold marker it couldn't remove kept db backup #{@old} " <>
                 "(db/kiln-#{@old}.hold: a directory, not a regular file)"

      # Fixed by hand: the sync has nothing to report, and the next pass
      # deletes the unit.
      File.rm_rf!(stuck)
      assert {:ok, _} = sync(ctx)
      refute_received {:notified, _, _}

      assert {:ok, %{deleted: deleted, kept: []}} = Retention.run(ctx.dir, notify: ctx.notify)
      assert "kiln-db-#{@old}.dump" in deleted
      assert {:ok, _} = sync(ctx)
      refute_received {:notified, _, _}
    end

    test "a hold the user can't remove (permissions) keeps it too", ctx do
      hold!(ctx.dir, "db", @old)
      db = Path.join(ctx.dir, "db")
      File.chmod!(db, 0o555)
      on_exit(fn -> File.chmod(db, 0o755) end)

      result = Retention.run(ctx.dir, notify: ctx.notify)
      File.chmod!(db, 0o755)

      if hold?(ctx.dir, "db", @old) do
        assert {:ok, %{kept: [%{stamp: @old, kind: :db, reason: {:remove, :eacces}}]}} = result
        assert File.exists?(Path.join([ctx.dir, "db", "kiln-db-#{@old}.dump"]))
      else
        # Running as root: permissions don't bind, so there is nothing to test.
        :ok
      end

      refute_received {:notified, _, _}
    end

    test "a hold that appears before the delete keeps the unit (the backstop)", ctx do
      before_unit = fn %{stamp: stamp, sub: sub} ->
        File.write!(Path.join([ctx.dir, sub, Artifact.hold_name(stamp)]), "")
      end

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{deleted: [], kept: kept}} =
                   Retention.run(ctx.dir, notify: ctx.notify, before_unit: before_unit)

          assert kept == [%{stamp: @old, kind: :db, reason: :still_there}]
        end)

      assert log =~
               "Retention kept db backup #{@old}: its hold marker db/kiln-#{@old}.hold was " <>
                 "still there right before the delete"

      assert File.exists?(Path.join([ctx.dir, "db", "kiln-db-#{@old}.dump"]))
    end
  end

  describe "held_deleted_candidates/2" do
    defp inventory(held, opts \\ []) do
      %{
        units: Keyword.get(opts, :units, %{}),
        markers: MapSet.new(),
        work: MapSet.new(Keyword.get(opts, :work, [])),
        strays: [],
        held: MapSet.new(held)
      }
    end

    defp unit(stamp, kind, roles) do
      %{
        stamp: stamp,
        kind: kind,
        partials: [],
        files:
          for(
            role <- roles,
            do: %{name: "x", role: role, part: nil, type: :regular, size: 1, mtime: 0}
          )
      }
    end

    defp run(status, kind, destinations, parts \\ []) do
      %{
        status: status,
        artifacts: [%{kind: kind, destinations: destinations, parts: parts}]
      }
    end

    test "absent or sidecar-only units, nothing else" do
      inv =
        inventory([{@old, :db}, {@older, :db}, {@new, :db}],
          units: %{
            {@older, :db} => unit(@older, :db, [:sidecar]),
            {@new, :db} => unit(@new, :db, [:data, :sidecar])
          }
        )

      assert Retention.held_deleted_candidates(inv, %{}) == [
               %{stamp: @older, kind: :db},
               %{stamp: @old, kind: :db}
             ]
    end

    test "not a stamp in flight: a .work/ directory, or a running Run" do
      assert Retention.held_deleted_candidates(inventory([{@old, :db}], work: [@old]), %{}) == []

      assert Retention.held_deleted_candidates(inventory([{@old, :db}]), %{
               @old => run(:running, :db, %{})
             }) == []
    end

    test "not one the app pruned here, the artifact or any part; another place's prune counts for nothing" do
      pruned = %{"local" => %{"status" => "pruned"}}
      inv = inventory([{@old, :media}])

      assert Retention.held_deleted_candidates(inv, %{@old => run(:succeeded, :media, pruned)}) ==
               []

      part = %{"name" => Artifact.part_name(@old, 1), "destinations" => pruned}

      assert Retention.held_deleted_candidates(inv, %{
               @old => run(:succeeded, :media, %{}, [part])
             }) == []

      # Pruned locally, but as the database, or on a destination: still reported.
      for run <- [
            run(:succeeded, :db, pruned),
            run(:succeeded, :media, %{"dest:x" => %{"status" => "pruned"}})
          ] do
        assert Retention.held_deleted_candidates(inv, %{@old => run}) == [
                 %{stamp: @old, kind: :media}
               ]
      end
    end
  end

  describe "the paths that sync holds" do
    test "run/2 reports a held unit deleted outside, never one of its own deletes", ctx do
      newest(ctx.dir)
      # Expired, and its hold stale: the plan deletes it.
      dump(ctx.dir, @old, 400)
      hold!(ctx.dir, "db", @old)
      hold!(ctx.dir, "db", @older)

      assert {:ok, %{deleted: deleted}} = Retention.run(ctx.dir, notify: ctx.notify)

      assert "kiln-db-#{@old}.dump" in deleted
      assert_received {:notified, _, [%{stamp: @older, kind: :db}]}

      assert {:ok, _} = Retention.run(ctx.dir, notify: ctx.notify)
      refute_received {:notified, _, _}
    end

    test "Chain.sync_last_good/2 writes the notice once the lock transaction commits", ctx do
      newest(ctx.dir)
      hold!(ctx.dir, "db", @older)

      assert {:ok, _} = Chain.sync_last_good(ctx.dir)

      assert [%{kind: :held_deleted, units: ["db:#{@older}"], total: 1}] =
               Backups.list_backup_notices!(actor: Backups.system())

      assert [%{units: ["db:#{@older}"], total: 1}] = Backups.status().held_deleted
    end
  end
end
