defmodule KilnCMS.Backups.RunTest do
  @moduledoc "Run writes: the log bound and scrubbing, and the stale sweep (#2217)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Backups

  defp stamp do
    n = System.unique_integer([:positive])
    "20260102-" <> String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0")
  end

  defp start!(attrs \\ %{}) do
    Backups.start_run!(Map.merge(%{stamp: stamp(), trigger: "test"}, attrs),
      actor: Backups.system()
    )
  end

  describe "the log bound" do
    test "an overlong log is stored as 50 + marker + 149, redacted and cut" do
      run = start!()

      log =
        for i <- 1..400 do
          %{step: "dump", message: "line #{i} password=hunter2pw " <> String.duplicate("z", 700)}
        end

      run = Backups.record_run_progress!(run, %{log: log}, actor: Backups.system())
      stored = Backups.get_run!(run.id, actor: Backups.system())

      assert length(stored.log) == 200
      assert Enum.count(stored.log, &(&1.step == "truncated")) == 1
      assert Enum.all?(stored.log, &(String.length(&1.message) <= 500))
      refute Enum.any?(stored.log, &(&1.message =~ "hunter2pw"))
    end

    test "the error is redacted and capped at 4000 characters, the trigger at 64" do
      run = start!(%{trigger: String.duplicate("t", 200)})
      assert String.length(run.trigger) == 64

      run =
        Backups.fail_run!(
          run,
          %{error: "boom postgres://u:pw12345@h/db " <> String.duplicate("e", 9_000)},
          actor: Backups.system()
        )

      assert run.status == :failed
      assert run.finished_at
      assert String.length(run.error) == 4_000
      refute run.error =~ "pw12345"
    end
  end

  describe "artifacts" do
    test "round-trip through the embedded array" do
      run = start!()
      {:ok, attrs} = Backups.Artifact.from_manifest(%{kind: "db", path: "db/a.dump", bytes: 9})

      run =
        Backups.finish_run!(run, %{artifacts: [attrs], components: [:db]},
          actor: Backups.system()
        )

      stored = Backups.get_run!(run.id, actor: Backups.system())
      assert stored.status == :succeeded
      assert [%{kind: :db, name: "a.dump", bytes: 9, parts: []}] = stored.artifacts
      assert stored.components == [:db]
    end
  end

  describe "off-site destinations (#2220)" do
    test "a new run has none, and round-trips them through the embedded array" do
      run = start!()
      assert run.destinations == []
      assert run.offsite_status == nil

      key = "dest:" <> Ash.UUID.generate()

      run =
        Backups.finish_run!(
          run,
          %{
            destinations: [
              %{key: "rclone:r2:b", kind: "rclone", status: :ok, files_ok: 2, files_total: 2},
              %{key: key, kind: "local", label: "NAS", status: :failed, error: "disk full"}
            ],
            offsite_status: :partial
          },
          actor: Backups.system()
        )

      stored = Backups.get_run!(run.id, actor: Backups.system())
      assert stored.offsite_status == :partial

      assert [
               %{key: "rclone:r2:b", status: :ok, files_ok: 2, files_total: 2, pruned: 0},
               %{key: ^key, label: "NAS", status: :failed, error: "disk full"}
             ] = stored.destinations
    end

    test "an unknown status is refused as input" do
      assert {:error, %Ash.Error.Invalid{}} =
               Backups.record_run_progress(start!(), %{offsite_status: :sideways},
                 actor: Backups.system()
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.record_run_progress(
                 start!(),
                 %{destinations: [%{key: "rclone:x", status: :teleported}]},
                 actor: Backups.system()
               )
    end

    test "a destination's error and label are redacted and capped" do
      secret_url = "https://user:pa55w0rdz@example.com/bucket"

      run =
        Backups.record_run_progress!(
          start!(),
          %{
            destinations: [
              %{
                key: "dest:" <> Ash.UUID.generate(),
                label: "Box " <> secret_url <> String.duplicate("l", 400),
                status: :failed,
                error: "upload to #{secret_url} refused " <> String.duplicate("e", 900)
              }
            ]
          },
          actor: Backups.system()
        )

      [entry] = Backups.get_run!(run.id, actor: Backups.system()).destinations
      refute entry.error =~ "pa55w0rdz"
      refute entry.label =~ "pa55w0rdz"
      assert entry.error =~ "example.com"
      assert String.length(entry.error) <= 500
      assert String.length(entry.label) <= 200
    end

    # A newer release may add values; this one must still read its rows.
    test "an unknown offsite_status or destination status written out of band loads as unknown" do
      import Ecto.Query

      run = start!()

      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "backup_runs",
            where: r.id == type(^run.id, :binary_id),
            update: [
              set: [
                offsite_status: "sideways",
                destinations:
                  type(
                    ^[
                      %{"key" => "rclone:x", "status" => "teleported", "files_ok" => 0},
                      %{"key" => "rclone:y", "status" => "ok", "files_ok" => 1}
                    ],
                    {:array, :map}
                  )
              ]
            ]
          ),
          []
        )

      stored = Backups.get_run!(run.id, actor: Backups.system())
      assert stored.offsite_status == %KilnCMS.Types.UnknownAtom{value: "sideways"}

      assert [
               %{key: "rclone:x", status: %KilnCMS.Types.UnknownAtom{value: "teleported"}},
               %{key: "rclone:y", status: :ok}
             ] = stored.destinations

      assert [%{offsite_status: %KilnCMS.Types.UnknownAtom{}}] =
               Backups.list_runs!(actor: Backups.system(), query: [filter: [id: run.id]])
    end
  end

  describe "a duplicate stamp" do
    test "start is refused by the unique identity" do
      run = start!()

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.start_run(%{stamp: run.stamp, trigger: "x"}, actor: Backups.system())
    end
  end

  # `updated_at` is stamped by the write that created the row, so a run that
  # went quiet has to be made quiet by hand.
  defp backdate!(run, at) do
    import Ecto.Query

    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "backup_runs", where: r.id == type(^run.id, :binary_id)),
        set: [updated_at: at]
      )

    run
  end

  describe "reconcile_stale_runs/1" do
    test "fails a run quiet for longer than the worker timeout plus grace, and only that one" do
      now = DateTime.utc_now()
      stale_at = DateTime.add(now, -(2 * 3600 + 16 * 60), :second)
      fresh_at = DateTime.add(now, -(2 * 3600 + 14 * 60), :second)

      stale = %{started_at: stale_at} |> start!() |> backdate!(stale_at)
      fresh = %{started_at: fresh_at} |> start!() |> backdate!(fresh_at)

      done = %{started_at: DateTime.add(now, -86_400, :second)} |> start!()
      Backups.finish_run!(done, %{}, actor: Backups.system())

      assert Backups.reconcile_stale_runs(now) == 1

      assert %{status: :failed, error: "Interrupted: " <> _, finished_at: %DateTime{}} =
               Backups.get_run!(stale.id, actor: Backups.system())

      assert Backups.get_run!(fresh.id, actor: Backups.system()).status == :running
      assert Backups.get_run!(done.id, actor: Backups.system()).status == :succeeded
    end

    test "a RESUMED run (old started_at, recently updated) is not failed; an untouched old one is" do
      # A resume keeps the original attempt's `started_at` and every progress
      # write bumps `updated_at`: going by `started_at` alone would fail a run
      # that is working, moments after it resumed.
      now = DateTime.utc_now()
      long_ago = DateTime.add(now, -3 * 86_400, :second)

      resumed = start!(%{started_at: long_ago})
      untouched = %{started_at: long_ago} |> start!() |> backdate!(long_ago)

      assert Backups.reconcile_stale_runs(now) == 1

      assert Backups.get_run!(resumed.id, actor: Backups.system()).status == :running
      assert Backups.get_run!(untouched.id, actor: Backups.system()).status == :failed
    end

    test "is idempotent" do
      now = DateTime.utc_now()
      long_ago = DateTime.add(now, -86_400, :second)
      %{started_at: long_ago} |> start!() |> backdate!(long_ago)

      assert Backups.reconcile_stale_runs(now) >= 1
      assert Backups.reconcile_stale_runs(now) == 0
    end
  end

  describe "the :resume action" do
    defp failed!(attrs \\ %{}) do
      run = start!(attrs)
      Backups.fail_run!(run, %{error: "boom"}, actor: Backups.system())
    end

    test "re-opens a failed run: running, outcome cleared, a log line added" do
      run = failed!()
      assert run.finished_at && run.error

      resumed = Backups.resume_run!(run, %{}, actor: Backups.system())

      assert resumed.status == :running
      assert resumed.finished_at == nil
      assert resumed.error == nil
      assert resumed.stamp == run.stamp
      assert resumed.started_at == run.started_at
      assert %{step: "resume", level: :info} = List.last(resumed.log)
    end

    test "clears the off-site outcome, unless it is given (#2220)" do
      run = start!()

      run =
        Backups.fail_run!(
          run,
          %{
            error: "boom",
            destinations: [%{key: "rclone:r", status: :failed, error: "nope"}],
            offsite_status: :failed
          },
          actor: Backups.system()
        )

      resumed = Backups.resume_run!(run, %{}, actor: Backups.system())
      assert resumed.destinations == []
      assert resumed.offsite_status == nil

      again = Backups.fail_run!(resumed, %{error: "boom"}, actor: Backups.system())

      settled =
        Backups.resume_run!(
          again,
          %{destinations: [%{key: "rclone:r", kind: "rclone"}]},
          actor: Backups.system()
        )

      assert [%{key: "rclone:r", status: :pending}] = settled.destinations
      assert settled.offsite_status == nil
    end

    test "re-opens a running run only when it has gone quiet" do
      quiet_at = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      quiet = %{started_at: quiet_at} |> start!() |> backdate!(quiet_at)
      live = start!()

      assert {:ok, _} =
               Backups.resume_run(Backups.get_run!(quiet.id, actor: Backups.system()), %{},
                 actor: Backups.system()
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Backups.resume_run(live, %{}, actor: Backups.system())
    end

    # #2421: the guard is re-checked in the UPDATE's WHERE. Both calls pass the
    # early check (the struct still says `failed`); only the filter can refuse
    # the second, so this fails if the filter is dropped.
    test "a second resume from the same stale struct is refused; the first chain keeps the row" do
      failed = failed!()
      chain_a = Ash.UUID.generate()
      chain_b = Ash.UUID.generate()

      assert {:ok, %{status: :running, chain_id: ^chain_a}} =
               Backups.resume_run(failed, %{chain_id: chain_a}, actor: Backups.system())

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.resume_run(failed, %{chain_id: chain_b}, actor: Backups.system())

      assert %{status: :running, chain_id: ^chain_a} =
               Backups.get_run!(failed.id, actor: Backups.system())
    end

    test "a stale struct of a run that went quiet is refused once another caller re-opened it" do
      quiet_at = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      quiet = %{started_at: quiet_at} |> start!() |> backdate!(quiet_at)
      quiet = Backups.get_run!(quiet.id, actor: Backups.system())
      chain_a = Ash.UUID.generate()

      assert {:ok, _} =
               Backups.resume_run(quiet, %{chain_id: chain_a}, actor: Backups.system())

      # The resume bumped `updated_at`, so the row is no longer stale.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.resume_run(quiet, %{chain_id: Ash.UUID.generate()},
                 actor: Backups.system()
               )

      assert %{chain_id: ^chain_a} = Backups.get_run!(quiet.id, actor: Backups.system())
    end

    # #2538: the Cancel cooldown lives only in the filter (the early check
    # keeps the Resume button visible), so a refusal here is the filter's.
    test "a run canceled moments ago passes the early check but the filter refuses it" do
      now = DateTime.utc_now()

      canceled =
        Ash.Seed.seed!(Backups.Run, %{stamp: stamp(), status: :canceled, finished_at: now})

      assert Backups.run_resumable?(canceled)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Backups.resume_run(canceled, %{}, actor: Backups.system())

      settled =
        DateTime.add(now, -(Backups.Heartbeat.settled_after_ms() + 1_000), :millisecond)

      for finished_at <- [settled, nil] do
        run =
          Ash.Seed.seed!(Backups.Run, %{
            stamp: stamp(),
            status: :canceled,
            finished_at: finished_at
          })

        assert {:ok, %{status: :running}} =
                 Backups.resume_run(run, %{}, actor: Backups.system())
      end
    end

    test "refuses a succeeded, skipped or imported run" do
      done = Backups.finish_run!(start!(), %{}, actor: Backups.system())

      skipped =
        Backups.skip_run!(%{stamp: stamp(), trigger: "t", error: "no pg_dump"},
          actor: Backups.system()
        )

      imported =
        Backups.import_run!(%{stamp: stamp(), trigger: "cron", status: :failed, error: "x"},
          actor: Backups.system()
        )

      for run <- [done, skipped, imported] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Backups.resume_run(run, %{}, actor: Backups.system())
      end
    end
  end
end
