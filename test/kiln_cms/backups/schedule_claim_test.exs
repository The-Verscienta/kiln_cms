defmodule KilnCMS.Backups.ScheduleClaimTest do
  @moduledoc """
  The window claim (#2219, part 2) on its own: a guarded, atomic update that
  matches zero rows when the window is already taken, the schedule is paused,
  or it was rebaselined past the window. A claim runs inside the backup lock
  transaction (`KilnCMS.Backups.Chain`), so a zero-row claim must come back as
  a returned error, never a raise, and the caller rolls the whole transaction
  back. Real concurrency (two connections) is in `SchedulerRaceTest`.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Chain
  alias KilnCMS.Repo

  @w ~U[2026-03-02 03:00:00.000000Z]

  defp claim(schedule, window_at, outcome \\ :started) do
    Backups.claim_backup_schedule_window(schedule, %{window_at: window_at, outcome: outcome},
      actor: Backups.system()
    )
  end

  defp past_baseline(schedule), do: force!(schedule, baseline_at: ~U[2026-01-01 00:00:00.000000Z])

  defp reload(schedule), do: Backups.get_backup_schedule!(schedule.id, actor: Backups.system())

  test "a successful claim sets last_window_at, last_outcome, last_outcome_at and clears last_error" do
    s = schedule!() |> past_baseline() |> force!(last_error: "earlier")
    before = DateTime.utc_now()

    assert {:ok, claimed} = claim(s, @w, :queued)
    assert claimed.last_window_at == @w
    assert claimed.last_outcome == :queued
    assert claimed.last_error == nil
    assert DateTime.compare(claimed.last_outcome_at, before) != :lt

    assert %{last_window_at: @w, last_outcome: :queued, last_error: nil} = reload(s)
  end

  test "a zero-row claim returns an error rather than raising, inside a transaction too" do
    s = past_baseline(schedule!())
    assert {:ok, _} = claim(s, @w)

    assert {:error, %Ash.Error.Invalid{}} = claim(s, @w)

    # Inside the lock transaction: the claim's error is a value the caller
    # sees, and rolls back with (here, the lock row `ensure` wrote).
    Repo.delete_all("backup_locks")

    assert {:error, :window_taken} =
             Chain.with_lock(fn _row ->
               case claim(s, @w) do
                 {:ok, _} -> {:ok, :claimed}
                 {:error, _} -> {:error, :window_taken}
               end
             end)

    assert Repo.aggregate("backup_locks", :count) == 0
  end

  test "a claim on a paused schedule, a rebaselined schedule, or an equal or older window matches zero rows" do
    admin = platform_admin()

    paused = past_baseline(schedule!())
    {:ok, paused} = Backups.update_backup_schedule(paused, %{enabled: false}, actor: admin)
    assert {:error, %Ash.Error.Invalid{}} = claim(paused, @w)

    # Rebaselined after the window: the window was before the schedule's
    # current timing existed.
    rebaselined = force!(schedule!(), baseline_at: DateTime.add(@w, 1, :second))
    assert {:error, %Ash.Error.Invalid{}} = claim(rebaselined, @w)

    taken = past_baseline(schedule!())
    assert {:ok, _} = claim(taken, @w)
    assert {:error, %Ash.Error.Invalid{}} = claim(taken, @w)
    assert {:error, %Ash.Error.Invalid{}} = claim(taken, DateTime.add(@w, -86_400, :second))
    assert %{last_window_at: @w} = reload(taken)

    # A later window still claims.
    assert {:ok, %{last_window_at: next}} = claim(taken, DateTime.add(@w, 86_400, :second))
    assert DateTime.compare(next, @w) == :gt
  end

  test "an outcome outside started, queued and folded is refused" do
    s = past_baseline(schedule!())
    assert {:error, %Ash.Error.Invalid{}} = claim(s, @w, :refused)
    assert %{last_window_at: nil} = reload(s)
  end
end
