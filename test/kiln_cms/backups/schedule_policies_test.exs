defmodule KilnCMS.Backups.SchedulePoliciesTest do
  @moduledoc """
  Who may touch an in-app backup schedule (part of #2219), and what the
  instance security log records of it.

  A platform admin reads and manages schedules; the window writes are the
  `:backups` system actor's alone. The refusals matter more than the grants: a
  site admin who is not a platform admin must not schedule backups of the
  whole instance, and a person who could claim or refuse a window could stop
  a scheduled backup from running (or forge one part 3's keep N would count).
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.Security
  alias KilnCMS.SystemActor

  @w ~U[2026-03-02 03:00:00.000000Z]

  defp refused_people,
    do: [user(:editor), user(:viewer), site_admin(), nil, SystemActor.new(:firing)]

  defp past_baseline(s), do: force!(s, baseline_at: ~U[2026-01-01 00:00:00.000000Z])

  defp events(type) do
    Security.list_instance_events!(actor: platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp window_writes do
    [
      claim_window: fn s, actor ->
        Backups.claim_backup_schedule_window(s, %{window_at: @w, outcome: :started}, actor: actor)
      end,
      refuse_window: fn s, actor ->
        Backups.refuse_backup_schedule_window(s, %{window_at: @w, reason: "disabled"},
          actor: actor
        )
      end,
      note_deferred: fn s, actor ->
        Backups.note_backup_schedule_deferred(s, %{window_at: @w, reason: "queue_busy"},
          actor: actor
        )
      end
    ]
  end

  describe "a platform admin" do
    test "can create, update and destroy; each records an instance event with its fields" do
      admin = platform_admin()

      s =
        schedule!(
          %{components: [:db], interval: :weekly, time_of_day: ~T[02:15:00]},
          admin
        )

      assert [%{target_type: "backup_schedule", target_id: id, actor_id: actor_id} = created] =
               events(:backup_schedule_created)

      assert id == s.id
      assert actor_id == admin.id

      assert created.metadata == %{
               "components" => "db",
               "interval" => "weekly",
               "time_of_day" => "02:15",
               "time_zone" => "Etc/UTC",
               "starts_on" => "2026-01-01",
               "enabled" => true
             }

      {:ok, s} = Backups.update_backup_schedule(s, %{interval: :daily}, actor: admin)
      assert [changed] = events(:backup_schedule_changed)

      assert %{"changed" => "interval", "interval" => "daily", "components" => "db"} =
               changed.metadata

      assert :ok = Backups.destroy_backup_schedule(s, actor: admin)
      assert [deleted] = events(:backup_schedule_deleted)
      assert deleted.target_id == s.id
      assert deleted.metadata == %{"components" => "db", "interval" => "daily", "enabled" => true}
    end

    test "a changed event carries keep_count and keep_days before and after" do
      admin = platform_admin()
      # No action accepts the keep fields yet (part 3); seeded in the table.
      s = force!(schedule!(%{}, admin), keep_count: 7, keep_days: 30)

      {:ok, _} = Backups.update_backup_schedule(s, %{enabled: false}, actor: admin)
      assert [changed] = events(:backup_schedule_changed)

      assert %{
               "changed" => "enabled",
               "enabled" => false,
               "keep_count_before" => 7,
               "keep_count_after" => 7,
               "keep_days_before" => 30,
               "keep_days_after" => 30
             } = changed.metadata
    end

    test "a deleted event carries keep_count and keep_days" do
      admin = platform_admin()
      s = force!(schedule!(%{}, admin), keep_count: 3, keep_days: 9)

      :ok = Backups.destroy_backup_schedule(s, actor: admin)

      assert [%{metadata: %{"keep_count" => 3, "keep_days" => 9}}] =
               events(:backup_schedule_deleted)
    end

    test "an edit that changes nothing records no changed event" do
      admin = platform_admin()
      s = schedule!(%{}, admin)

      {:ok, _} =
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

      assert events(:backup_schedule_changed) == []
    end

    test "cannot claim, refuse or note-deferred a window" do
      s = past_baseline(schedule!())
      admin = platform_admin()

      for {action, call} <- window_writes() do
        assert {:error, %Ash.Error.Forbidden{}} = call.(s, admin), "#{action} must refuse"
      end

      assert %{last_window_at: nil, last_deferred_window_at: nil} =
               Backups.get_backup_schedule!(s.id, actor: admin)
    end
  end

  describe "everyone else" do
    test "editor, viewer, an org admin who is not a platform admin, anonymous and another system actor are refused on every action" do
      s = past_baseline(schedule!())

      for actor <- refused_people() do
        label = inspect(actor && Map.get(actor, :role, actor))

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_backup_schedules(actor: actor, authorize_with: :error),
               "read must refuse #{label}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.create_backup_schedule(
                   %{
                     components: [:db],
                     interval: :daily,
                     time_of_day: ~T[03:00:00],
                     starts_on: ~D[2026-01-01]
                   },
                   actor: actor
                 ),
               "create must refuse #{label}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.update_backup_schedule(s, %{enabled: false}, actor: actor),
               "update must refuse #{label}"

        assert {:error, %Ash.Error.Forbidden{}} = Backups.destroy_backup_schedule(s, actor: actor),
               "destroy must refuse #{label}"

        for {action, call} <- window_writes() do
          assert {:error, %Ash.Error.Forbidden{}} = call.(s, actor),
                 "#{action} must refuse #{label}"
        end
      end

      assert %{enabled: true, last_window_at: nil} =
               Backups.get_backup_schedule!(s.id, actor: Backups.system())

      assert events(:backup_schedule_changed) == []
      assert events(:backup_schedule_deleted) == []
    end
  end

  describe "the :backups system actor" do
    test "can read, claim, refuse and note-deferred" do
      system = Backups.system()
      [claim, refuse, note] = for _ <- 1..3, do: past_baseline(schedule!())

      assert {:ok, listed} = Backups.list_backup_schedules(actor: system, authorize_with: :error)
      assert length(listed) == 3
      [{_, claim_fun}, {_, refuse_fun}, {_, note_fun}] = window_writes()

      assert {:ok, %{last_outcome: :started}} = claim_fun.(claim, system)
      assert {:ok, %{last_outcome: :refused}} = refuse_fun.(refuse, system)
      assert {:ok, %{last_outcome: :deferred}} = note_fun.(note, system)
    end

    test "cannot create, update or destroy" do
      s = schedule!()
      system = Backups.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.create_backup_schedule(
                 %{
                   components: [:db],
                   interval: :daily,
                   time_of_day: ~T[03:00:00],
                   starts_on: ~D[2026-01-01]
                 },
                 actor: system
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.update_backup_schedule(s, %{enabled: false}, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} = Backups.destroy_backup_schedule(s, actor: system)
    end
  end

  describe "W5: the fields no person writes" do
    @protected %{
      last_window_at: ~U[2030-01-01 00:00:00.000000Z],
      baseline_at: ~U[2020-01-01 00:00:00.000000Z],
      last_deferred_window_at: ~U[2030-01-01 00:00:00.000000Z],
      last_outcome: :started,
      last_outcome_at: ~U[2030-01-01 00:00:00.000000Z],
      last_error: "forged",
      keep_count: 5,
      keep_days: 10
    }

    test "create refuses each of them as input" do
      admin = platform_admin()

      base = %{
        components: [:db],
        interval: :daily,
        time_of_day: ~T[03:00:00],
        starts_on: ~D[2026-01-01]
      }

      for {field, value} <- @protected do
        assert {:error, %Ash.Error.Invalid{}} =
                 Backups.create_backup_schedule(Map.put(base, field, value), actor: admin),
               "create must refuse #{field}"
      end

      assert Backups.list_backup_schedules!(actor: admin) == []
    end

    test "update refuses each of them as input, and the row is unchanged" do
      admin = platform_admin()
      s = schedule!(%{}, admin)

      for {field, value} <- @protected do
        assert {:error, %Ash.Error.Invalid{}} =
                 Backups.update_backup_schedule(s, %{field => value}, actor: admin),
               "update must refuse #{field}"
      end

      after_ = Backups.get_backup_schedule!(s.id, actor: admin)

      for field <- Map.keys(@protected) do
        assert Map.get(after_, field) == Map.get(s, field), "#{field} must be unchanged"
      end
    end
  end
end
