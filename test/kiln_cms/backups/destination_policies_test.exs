defmodule KilnCMS.Backups.DestinationPoliciesTest do
  @moduledoc """
  Who may touch a stored backup destination (#2220).

  A platform admin reads and manages destinations; the backup pipeline reads
  them as the `:backups` system actor and records a Test's result, which no
  person may. The refusals matter more than the grants: a destination
  receives every site's data, so a site admin who is not a platform admin
  must not add one, and a person who could record a Test could make a broken
  destination look working.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.Test.BackupDestinations
  import KilnCMS.Test.BackupSchedules

  alias KilnCMS.Backups
  alias KilnCMS.SystemActor

  # Editor, viewer, an admin of the default site who is not a platform admin,
  # anonymous, and a system actor of another subsystem.
  defp refused_people,
    do: [user(:editor), user(:viewer), site_admin(), nil, SystemActor.new(:firing)]

  defp label(actor), do: inspect(actor && Map.get(actor, :role, actor))

  defp new_attrs,
    do: %{
      name: "Refused #{System.unique_integer([:positive])}",
      kind: "fake",
      settings: %{"mode" => "ok"}
    }

  describe "everyone else" do
    test "is refused on every action, and nothing changes" do
      d = destination!()

      for actor <- refused_people() do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_backup_destinations(actor: actor, authorize_with: :error),
               "read must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.list_enabled_backup_destinations(actor: actor, authorize_with: :error),
               "enabled must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.create_backup_destination(new_attrs(), actor: actor),
               "create must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.update_backup_destination(d, %{enabled: false}, actor: actor),
               "update must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.reorder_backup_destination(d, %{position: 3}, actor: actor),
               "reorder must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.destroy_backup_destination(d, actor: actor),
               "destroy must refuse #{label(actor)}"

        assert {:error, %Ash.Error.Forbidden{}} =
                 Backups.record_backup_destination_test(d, %{ok: true}, actor: actor),
               "record_test_result must refuse #{label(actor)}"
      end

      assert [%{enabled: true, last_tested_at: nil, position: 0}] =
               Backups.list_backup_destinations!(actor: Backups.system())
    end

    test "can't Test a destination: refused before the adapter is called" do
      d = destination!(%{settings: %{"mode" => "ok"}})

      for actor <- refused_people() do
        assert {:error, %Ash.Error.Forbidden{}} = Backups.test_destination(d.id, actor: actor),
               "test_destination must refuse #{label(actor)}"
      end

      # Fake notifies only when its settings name a pid; none is stored, so
      # the proof is the untouched row.
      assert %{last_tested_at: nil} =
               Backups.get_backup_destination!(d.id, actor: platform_admin())
    end

    test "an expired temporary platform grant is refused" do
      expired_grant = %{
        user(:editor)
        | granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.create_backup_destination(new_attrs(), actor: expired_grant)
    end
  end

  describe "the :backups system actor" do
    test "reads both ways and records a Test's result" do
      d = destination!()
      system = Backups.system()

      assert {:ok, [_]} = Backups.list_backup_destinations(actor: system, authorize_with: :error)

      assert {:ok, [_]} =
               Backups.list_enabled_backup_destinations(actor: system, authorize_with: :error)

      assert {:ok, %{last_test_ok: true}} =
               Backups.record_backup_destination_test(d, %{ok: true}, actor: system)
    end

    test "can't create, update or destroy" do
      d = destination!()
      system = Backups.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.create_backup_destination(new_attrs(), actor: system)

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.update_backup_destination(d, %{enabled: false}, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.reorder_backup_destination(d, %{position: 3}, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.destroy_backup_destination(d, actor: system)
    end
  end

  describe "a platform admin" do
    test "manages destinations" do
      admin = platform_admin()
      d = destination!(%{}, admin)

      assert {:ok, [_]} = Backups.list_backup_destinations(actor: admin, authorize_with: :error)

      assert {:ok, %{enabled: false} = d} =
               Backups.update_backup_destination(d, %{enabled: false}, actor: admin)

      # A reorder writes only the position, and leaves `updated_at` (#2952).
      assert {:ok, %{position: 3, enabled: false} = moved} =
               Backups.reorder_backup_destination(d, %{position: 3}, actor: admin)

      assert moved.updated_at == d.updated_at

      assert :ok = Backups.destroy_backup_destination(d, actor: admin)
    end

    test "can't record a Test's result directly" do
      d = destination!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.record_backup_destination_test(d, %{ok: true}, actor: platform_admin())
    end
  end
end
