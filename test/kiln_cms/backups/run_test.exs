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
