defmodule KilnCMS.Backups.RecorderTest do
  @moduledoc """
  The Recorder's Run-level destinations (#2220): the upsert, what they add up
  to, and their trip through `state.json` and the Run row.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Backups.{Recorder, RunDestination}

  defp stamp do
    n = System.unique_integer([:positive])
    "20260103-" <> String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0")
  end

  defp open!(destinations \\ []) do
    chain = Ash.UUID.generate()
    stamp = stamp()

    rec =
      Recorder.open(stamp, "test", DateTime.utc_now(), [:db], nil, chain, %{
        destinations: destinations
      })

    assert rec.run
    {rec, stamp, chain}
  end

  defp entry(key, status), do: %{key: key, status: status}

  defp unreadable_entry,
    do: %{key: RunDestination.unreadable_key(), status: :failed, error: "couldn't read"}

  describe "put_run_destination/3" do
    test "appends a new key as pending, and upserts an existing one" do
      rec = %Recorder{}

      rec = Recorder.put_run_destination(rec, "rclone:r", kind: "rclone", label: "Env")

      assert [%{key: "rclone:r", status: :pending, files_ok: 0, label: "Env"} = first] =
               rec.destinations

      refute Map.has_key?(first, :at)

      rec = Recorder.put_run_destination(rec, "dest:a", %{kind: "local"})
      rec = Recorder.put_run_destination(rec, "rclone:r", %{status: :ok, files_ok: 3})

      assert [
               %{key: "rclone:r", status: :ok, files_ok: 3, label: "Env", at: %DateTime{}},
               %{key: "dest:a", status: :pending, kind: "local"}
             ] = rec.destinations
    end

    test "redacts and caps the error and label" do
      rec =
        Recorder.put_run_destination(%Recorder{}, "dest:a", %{
          status: :failed,
          label: "https://u:s3cr3tpass@host/x",
          error: "password=hunter2xyz " <> String.duplicate("e", 900)
        })

      [entry] = rec.destinations
      refute entry.label =~ "s3cr3tpass"
      refute entry.error =~ "hunter2xyz"
      assert String.length(entry.error) == 500
    end

    test "ignores fields it doesn't know" do
      rec = Recorder.put_run_destination(%Recorder{}, "dest:a", %{secret: "x", status: :ok})
      [entry] = rec.destinations
      refute Map.has_key?(entry, :secret)
    end
  end

  describe "offsite_outcome/1" do
    test "none, complete, failed" do
      assert Recorder.offsite_outcome([]) == :none
      assert Recorder.offsite_outcome([entry("a", :skipped)]) == :none
      assert Recorder.offsite_outcome([entry("a", :ok), entry("b", :ok)]) == :complete
      assert Recorder.offsite_outcome([entry("a", :ok), entry("b", :skipped)]) == :complete
      assert Recorder.offsite_outcome([entry("a", :failed), entry("b", :failed)]) == :failed
    end

    test "mixed is partial" do
      assert Recorder.offsite_outcome([entry("a", :ok), entry("b", :failed)]) == :partial
    end

    test "a destination still pending never counts as complete or failed" do
      assert Recorder.offsite_outcome([entry("a", :ok), entry("b", :pending)]) == :partial
      assert Recorder.offsite_outcome([entry("a", :failed), entry("b", :pending)]) == :partial
    end

    # Critic change 12: a run an older release finished leaves every
    # destination pending; that is not "still sending".
    test "every destination still pending is unknown" do
      assert Recorder.offsite_outcome([entry("a", :pending)]) == :unknown
      assert Recorder.offsite_outcome([entry("a", :pending), entry("b", :pending)]) == :unknown
      assert Recorder.offsite_outcome([entry("a", :pending), entry("b", :skipped)]) == :unknown

      unreadable = entry(RunDestination.unreadable_key(), :failed)
      assert Recorder.offsite_outcome([entry("a", :pending), unreadable]) == :partial
    end

    test "an unknown status counts as neither reached nor failed" do
      unknown = %KilnCMS.Types.UnknownAtom{value: "teleported"}
      assert Recorder.offsite_outcome([entry("a", :ok), entry("b", unknown)]) == :partial
    end

    test "the unreadable entry never counts as complete" do
      unreadable = entry(RunDestination.unreadable_key(), :failed)

      assert Recorder.offsite_outcome([entry("a", :ok), unreadable]) == :partial
      # Every destination that could be read failed: nothing was reached.
      assert Recorder.offsite_outcome([entry("a", :failed), unreadable]) == :failed
    end

    # #2951: no `BACKUP_RCLONE_REMOTE` and an unreadable table reached
    # nothing at all; it is never "reached 0 of 1".
    test "the unreadable entry alone is failed, skipped entries beside it or not" do
      unreadable = entry(RunDestination.unreadable_key(), :failed)

      assert Recorder.offsite_outcome([unreadable]) == :failed
      assert Recorder.offsite_outcome([unreadable, entry("a", :skipped)]) == :failed
      assert Recorder.unreadable_only?([unreadable])
      assert Recorder.unreadable_only?([unreadable, entry("a", :skipped)])
      refute Recorder.unreadable_only?([unreadable, entry("a", :failed)])
      refute Recorder.unreadable_only?([entry("a", :skipped)])
      refute Recorder.unreadable_only?([])
    end

    test "takes the loaded embedded structs too" do
      assert Recorder.offsite_outcome([%RunDestination{key: "a", status: :ok}]) == :complete
    end
  end

  describe "across steps" do
    test "the destinations round-trip through state.json and load/3" do
      {rec, stamp, chain} = open!([%{key: "rclone:r", kind: "rclone", label: "Env"}])

      rec =
        rec
        |> Recorder.put_run_destination("dest:a", %{kind: "local", label: "NAS"})
        |> Recorder.put_run_destination("rclone:r", %{status: :ok, files_ok: 2, files_total: 2})
        |> Recorder.put_run_destination("dest:a", %{status: :failed, error: "disk full"})

      saved = rec |> Recorder.to_state() |> Jason.encode!() |> Jason.decode!()
      loaded = Recorder.load(stamp, chain, saved)

      assert loaded.run.id == rec.run.id
      assert loaded.destinations == rec.destinations

      assert [
               %{key: "rclone:r", status: :ok, files_ok: 2, at: %DateTime{}},
               %{key: "dest:a", status: :failed, error: "disk full", label: "NAS"}
             ] = loaded.destinations
    end

    test "state.json from before #2220, or with a status this release lacks, still loads" do
      assert Recorder.load(stamp(), Ash.UUID.generate(), %{"log" => []}).destinations == []

      saved = %{
        "destinations" => [
          %{"key" => "dest:a", "status" => "teleported", "bogus" => 1},
          %{"status" => "ok"},
          "junk"
        ]
      }

      assert [%{key: "dest:a", status: :pending} = only] =
               Recorder.load(stamp(), Ash.UUID.generate(), saved).destinations

      refute Map.has_key?(only, :bogus)
    end

    test "open/7 settles pending destinations on the run, and every write re-sends them" do
      {rec, _stamp, _chain} = open!([%{key: "rclone:r", kind: "rclone"}])
      assert [%{key: "rclone:r", status: :pending}] = rec.run.destinations

      rec =
        rec
        |> Recorder.put_run_destination("rclone:r", %{status: :ok})
        |> Recorder.progress()

      assert [%{key: "rclone:r", status: :ok}] = rec.run.destinations
      assert rec.run.offsite_status == nil
    end

    test "from_run/2 seeds them from the row" do
      {rec, stamp, chain} = open!([%{key: "rclone:r", kind: "rclone", label: "Env"}])
      rec |> Recorder.put_run_destination("rclone:r", %{status: :ok}) |> Recorder.progress()

      assert [%{key: "rclone:r", status: :ok, label: "Env"}] =
               Recorder.from_run(stamp, chain).destinations
    end
  end

  describe "the off-site outcome on the run" do
    test "finish records what the destinations add up to" do
      {rec, _stamp, _chain} = open!([%{key: "rclone:r"}, %{key: "dest:a"}])

      rec =
        rec
        |> Recorder.put_run_destination("rclone:r", %{status: :ok})
        |> Recorder.put_run_destination("dest:a", %{status: :failed, error: "x"})
        |> Recorder.finish()

      assert %{status: :succeeded, offsite_status: :partial} = rec.run
    end

    test "finish with every destination still pending leaves it nil, and still succeeds" do
      {rec, _stamp, _chain} = open!([%{key: "rclone:r"}])
      assert %{status: :succeeded, offsite_status: nil} = Recorder.finish(rec).run
    end

    test "finish with no destinations is none" do
      {rec, _stamp, _chain} = open!()
      assert %{offsite_status: :none} = Recorder.finish(rec).run
    end

    test "fail records failed when every destination failed" do
      {rec, _stamp, _chain} = open!([%{key: "rclone:r"}])

      rec =
        rec
        |> Recorder.put_run_destination("rclone:r", %{status: :failed, error: "x"})
        |> Recorder.fail("off-site copy failed")

      assert %{status: :failed, offsite_status: :failed} = rec.run
    end

    test "finish with only the unreadable entry is failed, and still succeeds (#2951)" do
      {rec, _stamp, _chain} = open!([unreadable_entry()])
      assert %{status: :succeeded, offsite_status: :failed} = Recorder.finish(rec).run
    end

    # The unreadable entry is recorded at the start, before anything was
    # tried: a run that failed with only it says nothing about off-site.
    test "fail with only the unreadable entry leaves it nil (#2951)" do
      {rec, _stamp, _chain} = open!([unreadable_entry()])
      assert %{status: :failed, offsite_status: nil} = Recorder.fail(rec, "dump failed").run
    end

    test "fail before the destinations settled leaves it nil" do
      {rec, _stamp, _chain} = open!([%{key: "rclone:r"}])
      assert %{status: :failed, offsite_status: nil} = Recorder.fail(rec, "dump failed").run
    end

    test "reopen/3 clears them for the resume to settle again" do
      {rec, stamp, _chain} = open!([%{key: "rclone:r"}])

      rec
      |> Recorder.put_run_destination("rclone:r", %{status: :failed, error: "x"})
      |> Recorder.fail("off-site copy failed")

      assert {:ok, resumed} = Recorder.reopen(stamp, Ash.UUID.generate())
      assert resumed.destinations == []
      assert %{destinations: [], offsite_status: nil, status: :running} = resumed.run
    end
  end

  test "a write with no run is a no-op" do
    rec = Recorder.put_run_destination(%Recorder{}, "rclone:r", %{status: :ok})
    assert Recorder.finish(rec) == rec
  end
end
