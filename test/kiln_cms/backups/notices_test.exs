defmodule KilnCMS.Backups.NoticesTest do
  @moduledoc """
  The notice writer (#2487, #2931): what each call leaves in
  `KilnCMS.Backups.Notice`, and that nothing it does reaches its caller.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.AfterCommit
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{DirId, Notice, Notices}
  alias KilnCMS.SystemActor

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_notices_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp notices, do: Backups.list_backup_notices!(actor: Backups.system())

  defp with_dir_id(dir) do
    id = Ash.UUID.generate()
    File.write!(DirId.path(dir), id)
    id
  end

  describe "retention/3" do
    test "a skip reports the place with Retention's words; a clean pass clears it", %{dir: dir} do
      assert :ok =
               Notices.retention({:local, dir}, {:skipped, {:policy, :invalid_policy}},
                 stamp: "20261116-020000"
               )

      assert [
               %Notice{
                 kind: :retention,
                 scope: "local",
                 dir_id: nil,
                 outcome: :skipped,
                 reason: reason,
                 stamp: "20261116-020000",
                 deleted: nil
               }
             ] = notices()

      assert reason == KilnCMS.Backups.Retention.describe({:policy, :invalid_policy})

      assert :ok = Notices.retention({:local, dir}, :ok)
      assert notices() == []
    end

    test "a directory with an id is its own scope, and its id is kept", %{dir: dir} do
      id = with_dir_id(dir)

      Notices.retention({:local, dir}, {:stopped, {:delete, "kiln-db-x.dump", :eacces}, 3})

      assert [%Notice{scope: scope, dir_id: ^id, outcome: :stopped, deleted: 3}] = notices()
      assert scope == "local:" <> id

      # A clean pass in an id-less directory clears its own scope only.
      other = Path.join(dir, "other")
      File.mkdir_p!(other)
      Notices.retention({:local, other}, :ok)
      assert [%Notice{scope: ^scope}] = notices()
    end

    test "a clean pass in a directory with an id also clears the id-less scope", %{dir: dir} do
      # Written while the directory's id couldn't be read.
      Notices.retention({:local, dir}, {:skipped, {:policy, :invalid_policy}})
      assert [%Notice{scope: "local"}] = notices()

      id = with_dir_id(dir)
      Notices.retention({:local, dir}, {:stopped, {:delete, "kiln-db-x.dump", :eacces}, 1})
      assert notices() |> Enum.map(& &1.scope) |> Enum.sort() == ["local", "local:" <> id]

      assert :ok = Notices.retention({:local, dir}, :ok)
      assert notices() == []
    end

    test "a long reason and label are cut, not refused", %{dir: dir} do
      Notices.retention({:local, dir}, {:skipped, String.duplicate("x", 2_000)})
      assert [%Notice{reason: reason}] = notices()
      assert String.length(reason) <= 500

      Notices.retention(
        {:destination, "dest:long", String.duplicate("y", 2_000)},
        {:skipped, :env_overlap}
      )

      assert %Notice{label: label} = Enum.find(notices(), &(&1.scope == "dest:long"))
      assert String.length(label) <= 200
    end

    test "a destination is scoped by its key and keeps its label" do
      Notices.retention({:destination, "dest:abc", "Offsite bucket"}, {:skipped, :env_overlap})

      assert [
               %Notice{
                 scope: "dest:abc",
                 label: "Offsite bucket",
                 reason: "it overlaps BACKUP_RCLONE_REMOTE"
               }
             ] = notices()

      Notices.retention({:destination, "dest:abc", "Offsite bucket"}, :ok)
      assert notices() == []
    end

    test "inside a transaction that rolls back, nothing is written", %{dir: dir} do
      assert {:error, :rolled_back} =
               AfterCommit.deferring(fn ->
                 Notices.retention({:local, dir}, {:skipped, :x})
                 {:error, :rolled_back}
               end)

      assert notices() == []

      assert {:ok, :committed} =
               AfterCommit.deferring(fn ->
                 Notices.retention({:local, dir}, {:skipped, :x})
                 {:ok, :committed}
               end)

      assert [%Notice{outcome: :skipped}] = notices()
    end

    test "a refused write is logged and counted, and never reaches the caller", %{dir: dir} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:kiln_cms, :backups, :notice, :failed]])

      log =
        capture_log(fn ->
          assert :ok =
                   Backups.with_actor(SystemActor.new(:security), fn ->
                     Notices.retention({:local, dir}, {:skipped, :x})
                   end)
        end)

      assert log =~ "Backup notice not recorded (retention)"

      assert_received {[:kiln_cms, :backups, :notice, :failed], ^ref, %{count: 1},
                       %{kind: :retention}}

      log =
        capture_log(fn ->
          assert :ok =
                   Backups.with_actor(SystemActor.new(:security), fn ->
                     Notices.retention({:local, dir}, :ok)
                   end)
        end)

      assert log =~ "Backup notice not recorded (retention)"
      assert notices() == []
    end
  end

  describe "held_deleted/2" do
    defp units(range, kind \\ :db), do: for(i <- range, do: %{stamp: stamp(i), kind: kind})
    defp stamp(i), do: "202601#{String.pad_leading("#{i}", 2, "0")}-020000"

    test "nothing for no units", %{dir: dir} do
      assert :ok = Notices.held_deleted(dir, [])
      assert notices() == []
    end

    test "lists the first ten and counts them all", %{dir: dir} do
      Notices.held_deleted(dir, units(1..12))

      assert [%Notice{kind: :held_deleted, scope: "local", units: listed, total: 12}] = notices()
      assert listed == Enum.map(1..10, &"db:#{stamp(&1)}")
    end

    test "a later detection merges into a recent one: earlier first, no unit twice", %{dir: dir} do
      id = with_dir_id(dir)
      Notices.held_deleted(dir, units(1..2))
      [%Notice{at: first_at}] = notices()

      Notices.held_deleted(dir, units(2..3) ++ units(1..1, :media))

      assert [%Notice{scope: scope, dir_id: ^id, units: listed, total: 4, at: at}] = notices()
      assert scope == "local:" <> id
      assert listed == ["db:#{stamp(1)}", "db:#{stamp(2)}", "db:#{stamp(3)}", "media:#{stamp(1)}"]
      assert DateTime.compare(at, first_at) == :gt
    end

    test "the merge keeps the ten-unit cap and keeps counting", %{dir: dir} do
      Notices.held_deleted(dir, units(1..9))
      Notices.held_deleted(dir, units(10..14))

      assert [%Notice{units: listed, total: 14}] = notices()
      assert length(listed) == 10
      assert hd(listed) == "db:#{stamp(1)}"
    end

    test "a notice older than the window is replaced, not merged into", %{dir: dir} do
      Notices.held_deleted(dir, units(1..2))

      old = DateTime.add(DateTime.utc_now(), -(Notices.held_deleted_days() + 1) * 86_400, :second)
      KilnCMS.Repo.query!("UPDATE backup_notices SET at = $1", [old])

      Notices.held_deleted(dir, units(5..5))

      assert [%Notice{units: ["db:" <> _], total: 1}] = notices()
    end

    test "a refused write is logged and never reaches the caller", %{dir: dir} do
      log =
        capture_log(fn ->
          assert :ok =
                   Backups.with_actor(SystemActor.new(:security), fn ->
                     Notices.held_deleted(dir, units(1..1))
                   end)
        end)

      assert log =~ "Backup notice not recorded (held_deleted)"
      assert notices() == []
    end
  end
end
