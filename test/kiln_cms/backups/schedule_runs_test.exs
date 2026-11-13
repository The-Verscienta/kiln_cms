defmodule KilnCMS.Backups.ScheduleRunsTest do
  @moduledoc """
  What the Schedule tab reads besides `Backups.status/0` (part of #2219):
  each schedule's newest run (`Backups.last_scheduled_runs/2`) and the
  scheduler's last tick (`Scheduler.last_tick_at/0`).
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Scheduler

  defp run!(n, schedule_ids, started_at) do
    stamp = "202601#{String.pad_leading(Integer.to_string(n), 2, "0")}-030000"

    Backups.start_run!(
      %{stamp: stamp, trigger: "schedule", schedule_ids: schedule_ids, started_at: started_at},
      actor: Backups.system()
    )
  end

  defp job!(worker, state, attempted_at) do
    KilnCMS.Repo.insert!(%Oban.Job{
      worker: worker,
      queue: "scheduling",
      args: %{},
      state: state,
      attempted_at: attempted_at
    })
  end

  describe "last_scheduled_runs/2" do
    # E7: one query per schedule, so a schedule that runs often never crowds
    # out the newest run of one that runs rarely (as `limit 5 * n` would).
    test "the newest run of each schedule, however many runs another has" do
      admin = platform_admin()
      often = schedule!(%{}, admin)
      rarely = schedule!(%{time_of_day: ~T[05:00:00]}, admin)
      never = schedule!(%{time_of_day: ~T[06:00:00]}, admin)

      old = run!(1, [rarely.id], ~U[2026-01-01 02:00:00.000000Z])

      for n <- 2..22 do
        run!(n, [often.id], DateTime.add(~U[2026-01-02 03:00:00.000000Z], n, :day))
      end

      newest = run!(28, [often.id, rarely.id], ~U[2026-01-01 04:00:00.000000Z])
      latest_often = run!(23, [often.id], ~U[2026-03-01 03:00:00.000000Z])

      assert {:ok, runs} = Backups.last_scheduled_runs([often.id, rarely.id, never.id], admin)

      assert runs[often.id].id == latest_often.id
      assert runs[rarely.id].id == newest.id
      refute runs[rarely.id].id == old.id
      assert Map.fetch!(runs, never.id) == nil
    end

    test "no ids, no reads" do
      assert {:ok, %{}} = Backups.last_scheduled_runs([], platform_admin())
    end

    test "a person who isn't a platform admin is refused" do
      s = schedule!(%{}, platform_admin())

      for actor <- [user(:editor), site_admin()] do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.last_scheduled_runs([s.id], actor)
      end
    end
  end

  describe "Scheduler.last_tick_at/0" do
    test "nil before any tick" do
      assert Scheduler.last_tick_at() == nil
    end

    test "the newest start of a scheduler job, whatever became of it" do
      worker = "KilnCMS.Backups.Scheduler"
      job!(worker, "completed", ~U[2026-01-01 00:00:00.000000Z])
      job!(worker, "discarded", ~U[2026-01-01 00:02:00.000000Z])
      # Not this worker, and not yet started: neither is a tick.
      job!("KilnCMS.Backups.MarkerSyncWorker", "completed", ~U[2026-01-01 00:05:00.000000Z])
      job!(worker, "available", nil)

      assert Scheduler.last_tick_at() == ~U[2026-01-01 00:02:00.000000Z]
    end
  end
end
