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

  describe "reconcile_stale_runs/1" do
    test "fails a run older than the worker timeout plus grace, and only that one" do
      now = ~U[2026-11-07 12:00:00.000000Z]
      stale = start!(%{started_at: DateTime.add(now, -(2 * 3600 + 16 * 60), :second)})
      fresh = start!(%{started_at: DateTime.add(now, -(2 * 3600 + 14 * 60), :second)})

      done = start!(%{started_at: DateTime.add(now, -86_400, :second)})
      Backups.finish_run!(done, %{}, actor: Backups.system())

      assert Backups.reconcile_stale_runs(now) == 1

      assert %{status: :failed, error: "Interrupted: " <> _, finished_at: %DateTime{}} =
               Backups.get_run!(stale.id, actor: Backups.system())

      assert Backups.get_run!(fresh.id, actor: Backups.system()).status == :running
      assert Backups.get_run!(done.id, actor: Backups.system()).status == :succeeded
    end

    test "is idempotent" do
      now = ~U[2026-11-07 12:00:00.000000Z]
      start!(%{started_at: DateTime.add(now, -86_400, :second)})

      assert Backups.reconcile_stale_runs(now) >= 1
      assert Backups.reconcile_stale_runs(now) == 0
    end
  end
end
