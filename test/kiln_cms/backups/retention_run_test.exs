defmodule KilnCMS.Backups.RetentionRunTest do
  @moduledoc """
  `Retention.run/2` against a real backup directory and run history (#2219):
  the importer first, the scan, failing closed, the last look before each
  delete, and the run history marking what went. The rules themselves are
  covered pure in `RetentionTest`.
  """
  # `async: false`: points `:kiln_cms, KilnCMS.Backups` at a temp directory
  # (`Application.put_env` is VM-global).
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Importer, Presence, Recorder, Retention}
  alias KilnCMS.Backups.Retention.Policy

  @moduletag :capture_log

  @day 24 * 3600
  @old "20200101-000000"
  @older "20190101-000000"
  @new "20260801-000000"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_retention_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, keep_days: 14)
    )

    on_exit(fn ->
      File.chmod(Path.join(dir, "media"), 0o700)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
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

  defp media_set(dir, stamp, ages, sidecar_age \\ nil) do
    for {age, i} <- Enum.with_index(ages, 1),
        do: put(dir, "media", Artifact.part_name(stamp, i), age)

    put(dir, "media", Artifact.sidecar_name(:media, stamp), sidecar_age || Enum.max(ages))
  end

  # A complete, settled (imported, so verified) backup of both kinds, a day old.
  defp newest(dir) do
    dump(dir, @new, 1)
    put(dir, "media", "kiln-media-#{@new}.tar.gz", 1)
  end

  # The backups left, without the last-good markers a run now writes (#2219);
  # `goods/1` lists those, and the tests that are about them use it.
  defp left(dir) do
    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(dir, sub)),
        Artifact.parse_good_name(name) == :error,
        do: "#{sub}/#{name}"
  end

  defp goods(dir) do
    for sub <- ["db", "media"],
        name <- File.ls!(Path.join(dir, sub)),
        String.ends_with?(name, ".good"),
        do: "#{sub}/#{name}"
  end

  defp stored(stamp), do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())

  describe "run/2" do
    test "imports cron-made backups first, classifies them by their rows, marks the pruned",
         %{dir: dir} do
      for stamp <- [@older, @old, @new], do: put(dir, "db", "kiln-db-#{stamp}.dump", 30)

      assert {:ok, %{deleted: deleted, units: 2, plan: plan}} = Retention.run(dir)

      assert Enum.sort(deleted) == ["kiln-db-#{@older}.dump", "kiln-db-#{@old}.dump"]
      assert left(dir) == ["db/kiln-db-#{@new}.dump"]

      # Kept because its imported row makes it the newest VERIFIED backup.
      assert [%{stamp: @new, reason: :newest_verified}] = plan.keep

      for stamp <- [@older, @old] do
        assert [%{destinations: %{"local" => %{"status" => "pruned"}}}] = stored(stamp).artifacts
      end

      assert [%{destinations: %{"local" => %{"status" => "ok"}}}] = stored(@new).artifacts
    end

    test "a whole old unit goes, sidecars included", %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [400, 380, 365])
      dump(dir, @old, 365)

      assert {:ok, %{deleted: deleted, units: 2}} = Retention.run(dir)

      assert Enum.sort(deleted) ==
               Enum.sort([
                 "kiln-media-#{@old}.part01.tar.gz",
                 "kiln-media-#{@old}.part02.tar.gz",
                 "kiln-media-#{@old}.part03.tar.gz",
                 "kiln-media-#{@old}.sha256",
                 "kiln-db-#{@old}.dump",
                 "kiln-db-#{@old}.sha256"
               ])

      assert Enum.all?(left(dir), &String.contains?(&1, @new))
    end

    test "one very old member does not take a unit with a fresh newest member", %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [365, 0], 365)

      assert {:ok, %{deleted: []}} = Retention.run(dir)
      assert length(left(dir)) == 6
    end

    test "the database and the media of one stamp age independently", %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [365, 365])
      dump(dir, @old, 0.5)

      assert {:ok, %{deleted: deleted}} = Retention.run(dir)
      assert Enum.all?(deleted, &String.starts_with?(&1, "kiln-media-#{@old}"))
      assert File.exists?(Path.join([dir, "db", "kiln-db-#{@old}.dump"]))
    end

    test "the (keep_days + 1) day boundary matches the shell", %{dir: dir} do
      newest(dir)
      media_set(dir, "20200101-000000", [14.9])
      media_set(dir, "20200202-000000", [15.1])

      assert {:ok, %{deleted: deleted}} = Retention.run(dir)

      assert Enum.sort(deleted) == [
               "kiln-media-20200202-000000.part01.tar.gz",
               "kiln-media-20200202-000000.sha256"
             ]
    end

    test "the newest complete unit stays even when it is old and nothing is verified",
         %{dir: dir} do
      # Parts without their sidecar: incomplete, so @new protects nothing and
      # the older complete set is the newest complete one.
      put(dir, "media", Artifact.part_name(@new, 1), 400)
      put(dir, "media", Artifact.part_name(@new, 2), 400)
      put(dir, "media", "kiln-media-#{@old}.tar.gz", 400)

      assert {:ok, %{deleted: deleted, plan: plan}} = Retention.run(dir)

      assert Enum.sort(deleted) == [
               Artifact.part_name(@new, 1),
               Artifact.part_name(@new, 2)
             ]

      assert [%{stamp: @old}] = plan.keep
    end

    test ".partial files are never deleted, and .work/<stamp> keeps its units", %{dir: dir} do
      newest(dir)
      partial = put(dir, "media", "kiln-media-#{@older}.part01.tar.gz.partial", 365)
      dump(dir, @old, 365)
      list = Path.join([dir, ".work", @old, "part01.list"])
      File.mkdir_p!(Path.dirname(list))
      File.write!(list, "x")

      assert {:ok, %{deleted: [], plan: plan}} = Retention.run(dir)
      assert File.exists?(partial)
      assert File.exists?(list)
      assert Enum.find(plan.keep, &(&1.stamp == @old)).reason == :in_flight
    end

    test "a fresh .partial keeps its unit in flight", %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [365, 365])
      put(dir, "media", Artifact.part_name(@old, 3) <> ".partial", 0)

      assert {:ok, %{deleted: []}} = Retention.run(dir)
    end

    test "a recovery point in either directory pins both components", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)
      media_set(dir, @old, [400])
      marker = put(dir, "media", Artifact.keep_name(@old), 400)

      assert {:ok, %{deleted: [], plan: plan}} = Retention.run(dir)

      assert %{"db" => :recovery_point, "media" => :recovery_point} =
               for(%{stamp: @old} = e <- plan.keep, into: %{}, do: {e.sub, e.reason})

      assert File.exists?(marker)
    end

    test "a marker is never a stray, never imported, and never removed", %{dir: dir} do
      newest(dir)
      marker = put(dir, "db", Artifact.keep_name(@old), 400)
      odd = put(dir, "db", "kiln-not-a-stamp.keep", 400)
      stray = put(dir, "media", "kiln-media-notes.txt", 400)
      young = put(dir, "media", "kiln-media-other.txt", 0)

      assert {:ok, %{deleted: ["kiln-media-notes.txt"]}} = Retention.run(dir)

      assert File.exists?(marker)
      assert File.exists?(odd)
      assert File.exists?(young)
      refute File.exists?(stray)

      assert {:ok, %{imported: 0}} = Importer.run(dir)
      assert {:ok, nil} = Backups.get_run_by_stamp(@old, actor: Backups.system())
    end

    test "a symlink is never deleted, nor what it points at", %{dir: dir} do
      newest(dir)
      target = Path.join(dir, "elsewhere.dump")
      File.write!(target, "precious")
      link = Path.join([dir, "db", "kiln-db-#{@old}.dump"])
      File.ln_s!(target, link)
      sidecar = put(dir, "db", Artifact.sidecar_name(:db, @old), 400)

      assert {:ok, %{deleted: deleted}} = Retention.run(dir)
      assert deleted == [Path.basename(sidecar)]
      assert {:ok, %{type: :symlink}} = File.lstat(link)
      assert File.read!(target) == "precious"
    end

    test "dry_run plans and deletes nothing", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)

      assert {:ok, %{deleted: [], units: 0, stopped: nil, plan: %{delete: [%{stamp: @old}]}}} =
               Retention.run(dir, dry_run: true)

      assert File.exists?(Path.join([dir, "db", "kiln-db-#{@old}.dump"]))
    end

    test "a policy function's policy is used", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 5)

      assert {:ok, %{deleted: [_, _]}} =
               Retention.run(dir, policy: fn -> {:ok, Policy.legacy(3)} end)
    end
  end

  describe "the last-good marker (#2219)" do
    setup do
      test_pid = self()
      handler = "last-good-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :backups, :last_good, :failed],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:last_good_failed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "is written in db/ and media/ for the newest verified unit, empty and 0600",
         %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)

      assert {:ok, %{plan: %{last_good: %{db: @new, media: @new}}}} = Retention.run(dir)

      assert goods(dir) == ["db/kiln-#{@new}.good", "media/kiln-#{@new}.good"]

      for sub <- ["db", "media"] do
        path = Path.join([dir, sub, Artifact.good_name(@new)])
        assert File.read!(path) == ""
        assert File.stat!(path).access == :read_write
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      end
    end

    test "moves: the new marker is written and the kind's old ones removed", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 1)
      put(dir, "db", Artifact.good_name(@old), 1, "")
      put(dir, "db", Artifact.good_name(@older), 1, "")
      put(dir, "media", Artifact.good_name(@old), 1, "")

      assert {:ok, %{deleted: []}} = Retention.run(dir)
      assert goods(dir) == ["db/kiln-#{@new}.good", "media/kiln-#{@new}.good"]
      refute_received {:last_good_failed, _, _}
    end

    test "a stale marker pins nothing in the app: its unit ages as usual", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)
      put(dir, "db", Artifact.good_name(@old), 400, "")

      assert {:ok, %{deleted: deleted, plan: plan}} = Retention.run(dir)
      assert Enum.sort(deleted) == ["kiln-db-#{@old}.dump", Artifact.sidecar_name(:db, @old)]
      refute Enum.any?(plan.delete ++ plan.keep, &(&1.kind == :stray))
      assert goods(dir) == ["db/kiln-#{@new}.good", "media/kiln-#{@new}.good"]
    end

    test "a dry run writes and removes no marker", %{dir: dir} do
      newest(dir)
      put(dir, "db", Artifact.good_name(@old), 1, "")

      assert {:ok, %{plan: %{last_good: %{db: @new}}}} = Retention.run(dir, dry_run: true)
      assert goods(dir) == ["db/kiln-#{@old}.good"]
    end

    test "a kind with no verified unit keeps the marker it has", %{dir: dir} do
      # A part without its sidecar: not complete, so no media unit is verified.
      dump(dir, @new, 1)
      put(dir, "media", Artifact.part_name(@old, 1), 1)
      put(dir, "media", Artifact.good_name(@older), 1, "")

      assert {:ok, %{plan: %{last_good: %{db: @new, media: nil}}}} = Retention.run(dir)
      assert goods(dir) == ["db/kiln-#{@new}.good", "media/kiln-#{@older}.good"]
    end

    test "retention skipped (grant revoked): no marker written or removed", %{dir: dir} do
      newest(dir)
      put(dir, "db", Artifact.good_name(@old), 1, "")

      assert {:error, {:import, _}} = Backups.with_actor(nil, fn -> Retention.run(dir) end)
      assert goods(dir) == ["db/kiln-#{@old}.good"]
    end

    test "a write that fails warns, reports, keeps the old marker, and pruning goes on",
         %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)
      put(dir, "db", Artifact.good_name(@old), 1, "")
      put(dir, "media", Artifact.good_name(@old), 1, "")
      db_marker = Path.join([dir, "db", Artifact.good_name(@new)])

      # Only the db marker's write fails; removing the old one would work.
      create = fn
        ^db_marker -> {:error, :enospc}
        path -> File.write(path, "")
      end

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{deleted: deleted}} = Retention.run(dir, create_marker: create)

          assert Enum.sort(deleted) ==
                   Enum.sort(["kiln-db-#{@old}.dump", Artifact.sidecar_name(:db, @old)])
        end)

      assert log =~ "Backup last-good marker db/kiln-#{@new}.good couldn't be written"
      assert_received {:last_good_failed, %{count: 1}, %{kind: :db, stamp: @new, reason: :enospc}}
      assert goods(dir) == ["db/kiln-#{@old}.good", "media/kiln-#{@new}.good"]
    end

    test "a directory it can't write to: the old marker stays, the rest goes on", %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [400])
      put(dir, "db", Artifact.good_name(@old), 1, "")
      db = Path.join(dir, "db")
      File.chmod!(db, 0o500)
      on_exit(fn -> File.chmod(db, 0o700) end)

      if match?({:error, _}, File.write(Path.join(db, "probe"), "")) do
        assert {:ok, %{deleted: deleted}} = Retention.run(dir)
        File.chmod!(db, 0o700)

        assert Enum.sort(deleted) ==
                 Enum.sort([Artifact.part_name(@old, 1), Artifact.sidecar_name(:media, @old)])

        assert_received {:last_good_failed, _, %{kind: :db, reason: :eacces}}
        assert goods(dir) == ["db/kiln-#{@old}.good", "media/kiln-#{@new}.good"]
      else
        # Running as root: permissions don't bind, so there is nothing to test.
        File.chmod!(db, 0o700)
      end
    end

    test "an old marker that is not a regular file is never removed", %{dir: dir} do
      newest(dir)
      File.mkdir_p!(Path.join([dir, "db", Artifact.good_name(@old)]))
      File.ln_s!("/nonexistent", Path.join([dir, "media", Artifact.good_name(@old)]))

      assert {:ok, _} = Retention.run(dir)

      # A marker the app can't clear pins its unit for cron for good: it
      # surfaces in telemetry, not only in the log.
      assert_received {:last_good_failed, %{count: 1}, %{reason: {:not_regular, :directory}}}
      assert_received {:last_good_failed, %{count: 1}, %{reason: {:not_regular, :symlink}}}

      assert goods(dir) == [
               "db/kiln-#{@new}.good",
               "db/kiln-#{@old}.good",
               "media/kiln-#{@new}.good",
               "media/kiln-#{@old}.good"
             ]

      assert File.dir?(Path.join([dir, "db", Artifact.good_name(@old)]))
    end

    test "sync_last_good/1 moves the markers and deletes no backup", %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)
      put(dir, "db", Artifact.good_name(@old), 1, "")
      before = Enum.sort(left(dir))

      assert {:ok, %{db: @new, media: @new}} = Retention.sync_last_good(dir)
      assert Enum.sort(left(dir)) == before
      assert goods(dir) == ["db/kiln-#{@new}.good", "media/kiln-#{@new}.good"]
    end

    test "sync_last_good/1 is total: an exit inside it is reported, not raised", %{dir: dir} do
      newest(dir)
      put(dir, "db", Artifact.good_name(@old), 1, "")

      capture_log([level: :warning], fn ->
        assert {:error, {:crashed, :exit}} =
                 Retention.sync_last_good(dir, create_marker: fn _path -> exit(:timeout) end)
      end)

      assert_received {:last_good_failed, %{count: 1}, %{reason: {:crashed, :exit}}}
      assert goods(dir) == ["db/kiln-#{@old}.good"]
    end

    test "sync_last_good/1 fails closed: a refused history writes and removes nothing",
         %{dir: dir} do
      newest(dir)
      put(dir, "db", Artifact.good_name(@old), 1, "")

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:import, _}} =
                   Backups.with_actor(nil, fn -> Retention.sync_last_good(dir) end)
        end)

      assert log =~ "Backup last-good marker not updated"
      assert_received {:last_good_failed, %{count: 1}, %{reason: {:import, _}}}
      assert goods(dir) == ["db/kiln-#{@old}.good"]
    end
  end

  describe "fails closed, loudly" do
    setup %{dir: dir} do
      newest(dir)
      dump(dir, @old, 400)
      media_set(dir, @old, [400, 400])

      test_pid = self()
      handler = "retention-skipped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :backups, :retention, :skipped],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:skipped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{before: Enum.sort(left(dir))}
    end

    test "with the grant revoked: the import fails, nothing is deleted", ctx do
      log =
        capture_log([level: :error], fn ->
          assert {:error, {:import, _}} =
                   Backups.with_actor(nil, fn -> Retention.run(ctx.dir) end)
        end)

      assert log =~ "[error]"
      assert log =~ "Backup retention skipped: couldn't import cron-made backups"
      assert log =~ "; nothing was deleted"
      assert_received {:skipped, %{count: 1}, %{reason: {:import, _}}}
      assert Enum.sort(left(ctx.dir)) == ctx.before
    end

    test "a refused run read is an error, never an empty history" do
      assert {:error, {:read_runs, _}} =
               Backups.with_actor(nil, fn -> Retention.read_runs([@old]) end)
    end

    test "a policy function that errors", ctx do
      assert {:error, {:policy, :schedule_unreadable}} =
               Retention.run(ctx.dir, policy: fn -> {:error, :schedule_unreadable} end)

      assert_received {:skipped, _, %{reason: {:policy, :schedule_unreadable}}}
      assert Enum.sort(left(ctx.dir)) == ctx.before
    end

    test "an invalid policy, or a function returning nonsense", ctx do
      assert {:error, {:policy, :invalid_policy}} =
               Retention.run(ctx.dir, policy: Policy.legacy(0))

      assert {:error, {:policy, :invalid_policy}} =
               Retention.run(ctx.dir, policy: fn -> {:ok, %{keep_days: 14}} end)

      assert {:error, {:policy, {:unexpected, :what}}} =
               Retention.run(ctx.dir, policy: fn -> :what end)

      assert Enum.sort(left(ctx.dir)) == ctx.before
    end

    test "a raising policy function is a crash, and still deletes nothing", ctx do
      assert {:error, {:crashed, RuntimeError}} =
               Retention.run(ctx.dir, policy: fn -> raise "boom" end)

      assert Enum.sort(left(ctx.dir)) == ctx.before
    end

    test "a .work that can't be listed (here: a file) rules nothing out", ctx do
      File.write!(Path.join(ctx.dir, ".work"), "not a directory")

      assert {:error, {:ls, ".work", :enotdir}} = Retention.run(ctx.dir)
      assert_received {:skipped, _, %{reason: {:ls, ".work", :enotdir}}}
      assert Enum.sort(left(ctx.dir)) == ctx.before
    end

    test "describe/1 says what went wrong, per reason" do
      assert Retention.describe({:import, :x}) =~ "couldn't import cron-made backups"

      assert Retention.describe({:read_runs, Ash.Error.Forbidden}) =~
               "couldn't read the backup history"

      assert Retention.describe({:policy, :invalid_policy}) =~ "the retention policy is invalid"
      assert Retention.describe({:policy, :down}) =~ "couldn't resolve the retention policy"
      assert Retention.describe({:ls, "media", :eacces}) =~ "couldn't list media/"

      assert Retention.describe({:lstat, "kiln-db-x.dump", :eio}) =~
               "couldn't read kiln-db-x.dump"

      assert Retention.describe({:crashed, RuntimeError}) =~ "it crashed"
    end

    test "an unreadable media/ directory", ctx do
      media = Path.join(ctx.dir, "media")
      File.chmod!(media, 0o000)

      if File.ls(media) == {:error, :eacces} do
        assert {:error, {:ls, "media", :eacces}} = Retention.scan(ctx.dir)
        assert {:error, _} = Retention.run(ctx.dir)
        File.chmod!(media, 0o700)
        assert Enum.sort(left(ctx.dir)) == ctx.before
      else
        # Running as root: permissions don't bind, so there is nothing to test.
        File.chmod!(media, 0o700)
      end
    end
  end

  describe "a delete that stops part-way" do
    test "what was deleted is marked pruned, and nobody is told nothing was", %{dir: dir} do
      for stamp <- ["20180101-000000", @older, @old, @new],
          do: put(dir, "db", "kiln-db-#{stamp}.dump", 30)

      test_pid = self()
      handler = "retention-stopped-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :backups, :retention, :stopped],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:stopped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Raise ahead of the second unit, once the first is gone.
      {:ok, seen} = Agent.start_link(fn -> 0 end)

      before_unit = fn _entry ->
        if Agent.get_and_update(seen, &{&1 + 1, &1 + 1}) == 2, do: raise("disk went away")
      end

      log =
        capture_log([level: :error], fn ->
          assert {:ok, %{deleted: ["kiln-db-20180101-000000.dump"], units: 1, stopped: stopped}} =
                   Retention.run(dir, before_unit: before_unit)

          assert stopped == {:crashed, RuntimeError}
        end)

      assert log =~ "Backup retention removed 1 file(s), then stopped: it crashed"
      refute log =~ "nothing was deleted"
      assert_received {:stopped, %{deleted: 1}, %{reason: {:crashed, RuntimeError}}}

      assert [%{destinations: %{"local" => %{"status" => "pruned"}}}] =
               stored("20180101-000000").artifacts

      # The units after the stop are untouched, and not marked.
      assert File.exists?(Path.join([dir, "db", "kiln-db-#{@older}.dump"]))
      assert [%{destinations: %{"local" => %{"status" => "ok"}}}] = stored(@older).artifacts
    end
  end

  describe "the last look before a delete" do
    setup %{dir: dir} do
      newest(dir)
      media_set(dir, @old, [400, 400])
      {:ok, %{plan: plan}} = Retention.run(dir, dry_run: true)
      assert [%{stamp: @old, kind: :media}] = plan.delete
      %{plan: plan, unit: Enum.sort(Path.wildcard(Path.join([dir, "media", "*#{@old}*"])))}
    end

    defp still_there?(unit), do: Enum.all?(unit, &File.exists?/1)

    test "a .work/<stamp> that appeared keeps the unit", ctx do
      File.mkdir_p!(Path.join([ctx.dir, ".work", @old]))
      assert {[], 0, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert still_there?(ctx.unit)
    end

    test "a marker that appeared keeps the unit", ctx do
      put(ctx.dir, "db", Artifact.keep_name(@old), 0)
      assert {[], 0, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert still_there?(ctx.unit)
    end

    test "a Run now running keeps the unit", ctx do
      # The plan's import recorded @old; no action turns an imported row back
      # to running, so the row is changed out of band.
      KilnCMS.Repo.update_all(
        from(r in "backup_runs", where: r.stamp == ^@old),
        set: [status: "running"]
      )

      assert %{status: :running} = stored(@old)
      assert {[], 0, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert still_there?(ctx.unit)
    end

    test "a Run that can't be read keeps the unit", ctx do
      assert {[], 0, nil} =
               Backups.with_actor(nil, fn -> Retention.apply_plan(ctx.dir, ctx.plan) end)

      assert still_there?(ctx.unit)
    end

    test "with nothing changed, the unit goes", ctx do
      assert {deleted, 1, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert length(deleted) == 3
      refute Enum.any?(ctx.unit, &File.exists?/1)
    end

    test "a file that can't be removed stops the unit; the sidecar stays", ctx do
      part01 = Path.join([ctx.dir, "media", Artifact.part_name(@old, 1)])
      File.rm!(part01)
      File.mkdir_p!(Path.join(part01, "inside"))

      assert {[], 0, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert File.exists?(Path.join([ctx.dir, "media", Artifact.part_name(@old, 2)]))
      assert File.exists?(Path.join([ctx.dir, "media", Artifact.sidecar_name(:media, @old)]))
    end

    test "a file already gone counts as removed", ctx do
      File.rm!(Path.join([ctx.dir, "media", Artifact.part_name(@old, 1)]))

      assert {deleted, 1, nil} = Retention.apply_plan(ctx.dir, ctx.plan)
      assert Artifact.part_name(@old, 1) in deleted
      assert length(deleted) == 3
      refute Enum.any?(ctx.unit, &File.exists?/1)
    end
  end

  describe "the run history" do
    defp run_with(artifacts, stamp \\ @old) do
      run =
        Backups.start_run!(
          %{stamp: stamp, trigger: "manual", started_at: ~U[2020-01-01 00:00:00Z]},
          actor: Backups.system()
        )

      Backups.finish_run!(run, %{artifacts: artifacts}, actor: Backups.system())
    end

    test "marks the whole part set and each part pruned; the sidecar name is ignored" do
      names = Artifact.set_names(@old, 2)
      parts = for name <- names, do: %{"name" => name, "bytes" => 1, "sha256" => nil}

      run_with([
        %{
          kind: :media,
          name: "kiln-media-#{@old}",
          bytes: 2,
          parts: parts,
          destinations: %{"local" => %{"status" => "ok"}, "rclone:r2" => %{"status" => "ok"}}
        }
      ])

      Recorder.mark_pruned(names ++ [Artifact.sidecar_name(:media, @old)])

      assert [artifact] = stored(@old).artifacts

      assert %{"local" => %{"status" => "pruned"}, "rclone:r2" => %{"status" => "ok"}} =
               artifact.destinations

      assert Enum.all?(artifact.parts, &(&1["destinations"]["local"]["status"] == "pruned"))
    end

    test "a set pruned only in part marks those parts, not the artifact" do
      [one, two] = Artifact.set_names(@old, 2)

      run_with([
        %{
          kind: :media,
          name: "kiln-media-#{@old}",
          bytes: 2,
          parts: [%{"name" => one, "bytes" => 1}, %{"name" => two, "bytes" => 1}],
          destinations: %{"local" => %{"status" => "ok"}}
        }
      ])

      Recorder.mark_pruned([one])

      assert [artifact] = stored(@old).artifacts
      assert artifact.destinations["local"]["status"] == "ok"
      assert [%{"destinations" => %{"local" => %{"status" => "pruned"}}}, second] = artifact.parts
      refute Map.has_key?(second, "destinations")
    end

    test "end to end: an app run's legacy single file is marked pruned", %{dir: dir} do
      newest(dir)
      put(dir, "media", "kiln-media-#{@old}.tar.gz", 365)

      {:ok, attrs} =
        Artifact.from_manifest(%{kind: "media", path: "media/kiln-media-#{@old}.tar.gz"})

      run = run_with([attrs])
      assert run.status == :succeeded
      assert {:ok, %{deleted: ["kiln-media-#{@old}.tar.gz"]}} = Retention.run(dir)

      # The run has finished, so the mark goes through `mark_pruned`, which
      # (unlike the chain's `record_progress`, #2218) takes no status filter.
      assert [%{destinations: %{"local" => %{"status" => "pruned"}}}] = stored(@old).artifacts
      assert Presence.for(stored(@old), dir, 14) == :pruned
    end
  end
end
