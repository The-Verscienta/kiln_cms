defmodule KilnCMS.Backups.PruneStatusTest do
  @moduledoc """
  The host's `backup.sh prune` status file (#3003): what each outcome leaves
  as the directory's cron retention notice, that reading the same file again
  changes nothing, that the app's own prune and cron's never clear each
  other's notice, and that a file it can't use is ignored with a log line.
  The script's side is in `KilnCMS.Scripts.BackupScriptTest`.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{DirId, Notice, Notices, PruneStatus}

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_prune_status_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp notices, do: Backups.list_backup_notices!(actor: Backups.system())

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

  defp status!(dir, fields) do
    body =
      Map.merge(
        %{"version" => 1, "at" => DateTime.to_iso8601(ago(60)), "warnings" => 0},
        fields
      )

    File.write!(PruneStatus.path(dir), Jason.encode!(body))
  end

  describe "sync/2" do
    test "a skip is the directory's cron notice, dated by the prune; ok clears it", %{dir: dir} do
      at = ago(3600)

      status!(dir, %{
        "at" => DateTime.to_iso8601(at),
        "outcome" => "skipped",
        "reason" => "could not list /var/backups/kiln/db",
        "warnings" => 1
      })

      assert :ok = PruneStatus.sync(dir)

      assert [
               %Notice{
                 kind: :retention,
                 scope: "cron",
                 dir_id: nil,
                 outcome: :skipped,
                 reason: "could not list /var/backups/kiln/db",
                 stamp: nil,
                 at: noticed_at
               }
             ] = notices()

      assert DateTime.compare(noticed_at, at) == :eq

      status!(dir, %{"outcome" => "ok", "reason" => nil})
      assert :ok = PruneStatus.sync(dir)
      assert notices() == []
    end

    test "partial is a stop, and counts the warnings it doesn't name", %{dir: dir} do
      id = Ash.UUID.generate()
      File.write!(DirId.path(dir), id)

      status!(dir, %{
        "outcome" => "partial",
        "reason" => "could not remove db/kiln-db-x.dump; kept the rest of db x",
        "warnings" => 3
      })

      PruneStatus.sync(dir)

      assert [%Notice{scope: scope, dir_id: ^id, outcome: :stopped, reason: reason}] = notices()
      assert scope == "cron:" <> id

      assert reason ==
               "could not remove db/kiln-db-x.dump; kept the rest of db x " <>
                 "(and 2 more warning(s) in the cron log)"
    end

    test "reading the same file again changes nothing", %{dir: dir} do
      status!(dir, %{"outcome" => "skipped", "reason" => "r"})
      PruneStatus.sync(dir)
      [first] = notices()

      PruneStatus.sync(dir)
      PruneStatus.sync(dir)
      assert [again] = notices()

      assert Map.take(again, [:id, :scope, :outcome, :reason, :at]) ==
               Map.take(first, [:id, :scope, :outcome, :reason, :at])

      status!(dir, %{"outcome" => "ok"})
      PruneStatus.sync(dir)
      PruneStatus.sync(dir)
      assert notices() == []
    end

    test "the app's prune and cron's never clear each other's notice", %{dir: dir} do
      Notices.retention({:local, dir}, {:skipped, {:policy, :invalid_policy}})
      status!(dir, %{"outcome" => "ok"})
      PruneStatus.sync(dir)
      assert [%Notice{scope: "local"}] = notices()

      status!(dir, %{"outcome" => "skipped", "reason" => "r"})
      PruneStatus.sync(dir)
      Notices.retention({:local, dir}, :ok)
      assert [%Notice{scope: "cron"}] = notices()
    end

    test "no file clears the cron notice, and logs nothing about the file", %{dir: dir} do
      Notices.retention({:local, dir}, {:skipped, {:policy, :invalid_policy}})
      Notices.retention({:cron, dir}, {:skipped, {:cron_prune, "r"}})

      log = capture_log(fn -> assert :ok = PruneStatus.sync(dir) end)
      refute log =~ PruneStatus.path(dir)

      # The app's own notice is not cron's to clear.
      assert [%Notice{scope: "local"}] = notices()
    end

    test "a malformed file is ignored with a warning, and leaves the notice", %{dir: dir} do
      Notices.retention({:cron, dir}, {:skipped, {:cron_prune, "r"}})

      for {body, why} <- [
            {"{not json", "it is not JSON"},
            {"[1]", "it is not a JSON object"},
            {~s({"version": 1, "at": "yesterday", "outcome": "ok"}), "its at is"},
            {~s({"version": 1, "at": "2026-11-18T03:00:00Z", "outcome": "fine"}),
             "its outcome is"},
            {~s({"at": "2026-11-18T03:00:00Z", "outcome": "ok"}), "its version is"},
            {~s({"version": 1, "at": "2026-11-18T03:00:00Z", "outcome": "ok", "reason": 7}),
             "its reason is"},
            {String.duplicate(" ", 5000), "it is larger than 4096 bytes"}
          ] do
        File.write!(PruneStatus.path(dir), body)

        log = capture_log([level: :warning], fn -> assert :ok = PruneStatus.sync(dir) end)
        assert log =~ "Ignored #{PruneStatus.path(dir)}: #{why}", body
      end

      assert [%Notice{scope: "cron", outcome: :skipped}] = notices()
    end

    test "a file dated ahead of this node's clock is ignored with a warning", %{dir: dir} do
      Notices.retention({:cron, dir}, {:skipped, {:cron_prune, "r"}})

      status!(dir, %{"outcome" => "ok", "at" => DateTime.to_iso8601(ago(-3600))})
      log = capture_log([level: :warning], fn -> PruneStatus.sync(dir) end)
      assert log =~ "Ignored #{PruneStatus.path(dir)}: it is dated"
      assert log =~ "ahead of this node's clock"

      assert [%Notice{scope: "cron"}] = notices()
    end

    test "the longest reason the script writes is applied, cut like any notice", %{dir: dir} do
      status!(dir, %{"outcome" => "skipped", "reason" => String.duplicate("é", 500)})
      assert byte_size(File.read!(PruneStatus.path(dir))) < 4096

      PruneStatus.sync(dir)
      assert [%Notice{outcome: :skipped, reason: reason}] = notices()
      assert String.length(reason) <= 500
    end

    test "fields a later script adds are ignored", %{dir: dir} do
      status!(dir, %{"version" => 2, "outcome" => "skipped", "reason" => "r", "new" => [1]})
      PruneStatus.sync(dir)
      assert [%Notice{outcome: :skipped}] = notices()
    end
  end
end

defmodule KilnCMS.Backups.PruneStatusOldFileTest do
  @moduledoc """
  An old prune status file (#3003) is ignored with an info line.

  `async: false`: the line is below the test config's log level, and
  `Logger.configure/1` is VM-global.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Notices, PruneStatus}

  test "a file older than eight days is ignored, and clears the cron notice" do
    dir = Path.join(System.tmp_dir!(), "kiln_prune_status_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    Notices.retention({:cron, dir}, {:skipped, {:cron_prune, "r"}})
    at = DateTime.utc_now() |> DateTime.add(-9 * 86_400) |> DateTime.to_iso8601()

    File.write!(
      PruneStatus.path(dir),
      Jason.encode!(%{version: 1, at: at, outcome: "ok", reason: nil, warnings: 0})
    )

    log = capture_log([level: :info], fn -> assert :ok = PruneStatus.sync(dir) end)

    assert log =~
             "Ignored #{PruneStatus.path(dir)}: written #{at}, more than 8 days ago; " <>
               "the cron prune's notice is cleared"

    assert Backups.list_backup_notices!(actor: Backups.system()) == []
  end
end
