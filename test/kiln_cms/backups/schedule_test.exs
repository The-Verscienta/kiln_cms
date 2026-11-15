defmodule KilnCMS.Backups.ScheduleTest do
  @moduledoc """
  A backup schedule's validations and its own bookkeeping (part of #2219):
  what create and update store, when the baseline moves, and how the reason a
  window did not run is kept.

  `async: false`: the media-directory cases change the VM-wide backup config.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups

  @w ~U[2026-03-02 03:00:00.000000Z]

  defp attrs(extra) do
    Map.merge(
      %{
        components: [:db],
        interval: :daily,
        time_of_day: ~T[03:00:00],
        starts_on: ~D[2026-01-01]
      },
      extra
    )
  end

  defp create(extra, actor \\ platform_admin()),
    do: Backups.create_backup_schedule(attrs(extra), actor: actor)

  defp with_media_dir(value) do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(original, :media_dir, value)
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)
  end

  defp error_fields(%{errors: errors}), do: Enum.map(errors, &Map.get(&1, :field))

  describe "validations" do
    test "an unknown time zone is refused" do
      assert {:error, error} = create(%{time_zone: "Mars/Olympus_Mons"})
      assert :time_zone in error_fields(error)
      assert Exception.message(error) =~ "is not a known time zone"
    end

    test "empty components are refused; duplicates are folded and ordered" do
      assert {:error, %Ash.Error.Invalid{}} = create(%{components: []})

      with_media_dir(System.tmp_dir!())
      assert {:ok, s} = create(%{components: [:media, :db, :media]})
      assert s.components == [:db, :media]
    end

    test "media is refused without a media directory" do
      with_media_dir(nil)
      assert {:error, error} = create(%{components: [:db, :media]})
      assert :components in error_fields(error)
    end

    test "a media schedule whose directory went away can still be paused" do
      with_media_dir(System.tmp_dir!())
      admin = platform_admin()
      {:ok, s} = create(%{components: [:media]}, admin)

      with_media_dir(nil)

      assert {:ok, %{enabled: false}} =
               Backups.update_backup_schedule(s, %{enabled: false}, actor: admin)
    end

    # D2: every run is a full set and retention is age-only until keep N.
    test "sub-daily intervals are refused until keep-N retention exists" do
      for interval <- [:every_2h, :every_4h, :every_8h, :every_12h] do
        assert {:error, error} = create(%{interval: interval})
        assert Exception.message(error) =~ "sub-daily schedules arrive with keep-N retention"
      end

      for interval <- [:daily, :weekly, :fortnightly, :monthly] do
        assert {:ok, %{interval: ^interval}} = create(%{interval: interval})
      end
    end

    test "keep fields don't lift the sub-daily refusal (#2219)" do
      assert {:error, error} = create(%{interval: :every_2h, keep_count: 12, keep_days: 2})
      assert :interval in error_fields(error)
    end

    test "keep fields out of range are refused (#2219)" do
      for {field, value} <- [
            keep_count: 0,
            keep_count: -1,
            keep_count: 1001,
            keep_days: 0,
            keep_days: 3651
          ] do
        assert {:error, error} = create(%{field => value}), "#{field}: #{value}"
        assert field in error_fields(error)
      end

      assert {:ok, %{keep_count: 1000, keep_days: 3650}} =
               create(%{keep_count: 1000, keep_days: 3650})
    end

    test "keep_days alone must cover one interval (#2219)" do
      for {interval, short, enough} <- [
            {:daily, nil, 1},
            {:weekly, 6, 7},
            {:fortnightly, 13, 14},
            {:monthly, 30, 31}
          ] do
        if short do
          assert {:error, error} = create(%{interval: interval, keep_days: short})
          assert :keep_days in error_fields(error)
          assert Exception.message(error) =~ "at least as long as the schedule's interval"

          # A count keeps the backups however short the days.
          assert {:ok, _} = create(%{interval: interval, keep_days: short, keep_count: 2})
        end

        assert {:ok, _} = create(%{interval: interval, keep_days: enough})
      end
    end

    test "keep_days is checked again when the interval or the count changes (#2219)" do
      admin = platform_admin()
      {:ok, s} = create(%{keep_days: 3}, admin)

      assert {:error, error} =
               Backups.update_backup_schedule(s, %{interval: :weekly}, actor: admin)

      assert :keep_days in error_fields(error)

      {:ok, s} = Backups.update_backup_schedule(s, %{keep_count: 4}, actor: admin)
      {:ok, s} = Backups.update_backup_schedule(s, %{interval: :weekly}, actor: admin)

      assert {:error, error} = Backups.update_backup_schedule(s, %{keep_count: nil}, actor: admin)
      assert :keep_days in error_fields(error)

      # An unrelated edit of a row that breaks the rule (a newer release's)
      # is not refused for it.
      s = force!(s, keep_count: nil)

      assert {:ok, %{enabled: false}} =
               Backups.update_backup_schedule(s, %{enabled: false}, actor: admin)
    end

    test "an unknown interval is refused" do
      assert {:error, %Ash.Error.Invalid{}} = create(%{interval: :hourly})
    end
  end

  describe "the marker sync after a change (#2219)" do
    defp sync_jobs do
      worker = inspect(KilnCMS.Backups.MarkerSyncWorker)
      KilnCMS.Repo.all(from(j in Oban.Job, where: j.worker == ^worker and j.state == "available"))
    end

    defp clear_sync_jobs, do: KilnCMS.Repo.delete_all(Oban.Job)

    test "a create, an update and a destroy each queue one, after the commit" do
      admin = platform_admin()
      {:ok, s} = create(%{keep_count: 3}, admin)
      assert [%{args: args}] = sync_jobs()
      assert args == %{}

      clear_sync_jobs()
      {:ok, s} = Backups.update_backup_schedule(s, %{keep_count: 4}, actor: admin)
      assert [_] = sync_jobs()

      clear_sync_jobs()
      :ok = Backups.destroy_backup_schedule(s, actor: admin)
      assert [_] = sync_jobs()
    end

    test "a refused change queues none" do
      assert {:error, _} = create(%{keep_count: 0})
      assert {:error, _} = create(%{}, user(:editor))
      assert sync_jobs() == []
    end

    test "none while the marker sync is turned off" do
      original = Application.get_env(:kiln_cms, :backup_marker_sync_cron)
      Application.put_env(:kiln_cms, :backup_marker_sync_cron, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :backup_marker_sync_cron, original) end)

      assert {:ok, _} = create(%{keep_count: 3})
      assert sync_jobs() == []
    end
  end

  test "time_of_day is truncated to the minute" do
    assert {:ok, s} = create(%{time_of_day: ~T[03:17:42.123456]})
    assert Time.compare(s.time_of_day, ~T[03:17:00]) == :eq
  end

  test "W-j: baseline_at comes from the node clock at create" do
    before = DateTime.utc_now()
    assert {:ok, s} = create(%{})
    after_ = DateTime.utc_now()

    assert DateTime.compare(s.baseline_at, before) != :lt
    assert DateTime.compare(s.baseline_at, after_) != :gt
  end

  describe "W6: rebaseline" do
    setup do
      admin = platform_admin()
      old = ~U[2026-01-01 00:00:00.000000Z]
      with_media_dir(System.tmp_dir!())
      %{admin: admin, s: force!(schedule!(%{}, admin), baseline_at: old), old: old}
    end

    test "on an interval, time, zone, start date or components change, and on resume",
         %{admin: admin, s: s, old: old} do
      for change <- [
            %{interval: :weekly},
            %{time_of_day: ~T[04:00:00]},
            %{time_zone: "Europe/Paris"},
            %{starts_on: ~D[2026-02-01]},
            %{components: [:db, :media]}
          ] do
        s = force!(s, baseline_at: old)
        {:ok, updated} = Backups.update_backup_schedule(s, change, actor: admin)

        assert DateTime.compare(updated.baseline_at, old) == :gt,
               "#{inspect(change)} must rebaseline"
      end

      paused = force!(s, baseline_at: old, enabled: false)
      {:ok, resumed} = Backups.update_backup_schedule(paused, %{enabled: true}, actor: admin)
      assert DateTime.compare(resumed.baseline_at, old) == :gt
    end

    test "not on pause, and not on an unchanged resubmit", %{admin: admin, s: s, old: old} do
      {:ok, same} =
        Backups.update_backup_schedule(
          s,
          %{
            components: [:db],
            interval: :daily,
            time_of_day: ~T[03:00:00],
            starts_on: ~D[2026-01-01],
            time_zone: "Etc/UTC",
            enabled: true
          },
          actor: admin
        )

      assert same.baseline_at == old

      {:ok, paused} = Backups.update_backup_schedule(s, %{enabled: false}, actor: admin)
      assert paused.baseline_at == old
    end
  end

  test "last_error is redacted and capped" do
    s = force!(schedule!(), baseline_at: ~U[2026-01-01 00:00:00.000000Z])
    reason = "pg_dump failed: password=hunter2 " <> String.duplicate("x", 2_000)

    assert {:ok, refused} =
             Backups.refuse_backup_schedule_window(s, %{window_at: @w, reason: reason},
               actor: Backups.system()
             )

    refute refused.last_error =~ "hunter2"
    assert refused.last_error =~ "password=***"
    assert String.length(refused.last_error) == 500
    assert refused.last_window_at == @w
  end

  test "note_deferred notes a window once and never moves last_window_at" do
    s = force!(schedule!(), baseline_at: ~U[2026-01-01 00:00:00.000000Z])

    note =
      &Backups.note_backup_schedule_deferred(&1, %{window_at: @w, reason: "queue_busy"},
        actor: Backups.system()
      )

    assert {:ok, noted} = note.(s)
    assert noted.last_deferred_window_at == @w
    assert noted.last_window_at == nil
    assert noted.last_outcome == :deferred

    assert {:error, %Ash.Error.Invalid{}} = note.(noted)
  end
end
