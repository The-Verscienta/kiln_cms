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

  # The page of the history a "Last scheduled run" link opens (#2875).
  describe "history_page_of/3" do
    test "the page that holds the run, newest first" do
      admin = platform_admin()

      [oldest, middle, newest] =
        for n <- 1..3, do: run!(n, [], DateTime.add(~U[2026-01-01 00:00:00.000000Z], n, :hour))

      assert Backups.history_page_of(newest.id, admin, 1) == {:ok, 1}
      assert Backups.history_page_of(middle.id, admin, 1) == {:ok, 2}
      assert Backups.history_page_of(oldest.id, admin, 1) == {:ok, 3}
      assert Backups.history_page_of(oldest.id, admin, 2) == {:ok, 2}
      assert Backups.history_page_of(oldest.id, admin, 25) == {:ok, 1}
    end

    test "a run that doesn't exist, or an id that isn't one, is an error" do
      admin = platform_admin()

      assert {:error, _} = Backups.history_page_of(Ecto.UUID.generate(), admin, 25)
      assert {:error, _} = Backups.history_page_of("not-a-uuid", admin, 25)
    end

    # The probe: a refused count is 0, which would answer page 1 for any run.
    # The `:backups` system actor reads runs but not the history page, so it
    # is the case where only the count is refused.
    test "an actor who may not read the history is refused, never answered page 1" do
      run = run!(1, [], ~U[2026-01-01 00:00:00.000000Z])
      run!(2, [], ~U[2026-01-01 01:00:00.000000Z])

      for actor <- [user(:editor), site_admin(), Backups.system()] do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.history_page_of(run.id, actor, 1)
      end
    end
  end

  describe "Scheduler.last_tick_at/0" do
    test "nil before any tick" do
      assert Scheduler.last_tick_at() == {:ok, nil}
    end

    test "the newest start of a scheduler job, whatever became of it" do
      worker = "KilnCMS.Backups.Scheduler"
      job!(worker, "completed", ~U[2026-01-01 00:00:00.000000Z])
      job!(worker, "discarded", ~U[2026-01-01 00:02:00.000000Z])
      # Not this worker, and not yet started: neither is a tick.
      job!("KilnCMS.Backups.MarkerSyncWorker", "completed", ~U[2026-01-01 00:05:00.000000Z])
      job!(worker, "available", nil)

      assert Scheduler.last_tick_at() == {:ok, ~U[2026-01-01 00:02:00.000000Z]}
    end
  end
end
