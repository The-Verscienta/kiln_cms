defmodule KilnCMS.Accounts.BackupReportPreferenceTest do
  @moduledoc """
  `User.notify_on_backup` (#2229): `:failures` by default, visible to the
  account holder and platform admins only, changeable by the account holder
  alone, reset by erasure and included in the data export.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "backup-pref-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    %{admin: user(:admin), other_admin: user(:admin), editor: user(:editor)}
  end

  test ":failures by default", ctx do
    assert ctx.admin.notify_on_backup == :failures
  end

  test "the account holder can choose every run, off, and back", ctx do
    assert {:ok, %{notify_on_backup: :every_run} = every} =
             Accounts.update_notification_prefs(ctx.admin, %{notify_on_backup: :every_run},
               actor: ctx.admin
             )

    assert {:ok, %{notify_on_backup: :off} = off} =
             Accounts.update_notification_prefs(every, %{notify_on_backup: "off"},
               actor: ctx.admin
             )

    assert {:ok, %{notify_on_backup: :failures}} =
             Accounts.update_notification_prefs(off, %{notify_on_backup: :failures},
               actor: ctx.admin
             )
  end

  test "a value outside the three is refused", ctx do
    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.update_notification_prefs(ctx.admin, %{notify_on_backup: :weekly},
               actor: ctx.admin
             )
  end

  test "another platform admin can't change it, but can still change the other preferences",
       ctx do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Accounts.update_notification_prefs(ctx.admin, %{notify_on_backup: :off},
               actor: ctx.other_admin
             )

    assert Exception.message(error) =~ "account holder"

    assert {:ok, %{notify_on_comment: false, notify_on_backup: :failures}} =
             Accounts.update_notification_prefs(ctx.admin, %{notify_on_comment: false},
               actor: ctx.other_admin
             )
  end

  test "the security alert mute is still the account holder's own", ctx do
    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.update_notification_prefs(ctx.editor, %{notify_on_security_alert: false},
               actor: ctx.admin
             )
  end

  test "the field policy hides it from other users", ctx do
    assert {:ok, %{notify_on_backup: :failures}} =
             Accounts.get_user(ctx.admin.id, actor: ctx.admin)

    assert {:ok, %{notify_on_backup: :failures}} =
             Accounts.get_user(ctx.admin.id, actor: ctx.other_admin)

    # Guarded by the admin/self field policy, as the other preferences are, so
    # a byline load (`author`) never carries it.
    guarded =
      User
      |> Ash.Policy.Info.field_policies()
      |> Enum.reject(&(&1.fields == :* or &1.fields == [:*]))
      |> Enum.flat_map(&List.wrap(&1.fields))

    assert :notify_on_backup in guarded

    # A user who is neither reads nothing of the account.
    assert {:error, _refused} = Accounts.get_user(ctx.admin.id, actor: ctx.editor)
  end

  test "erasure resets it to the default", ctx do
    {:ok, every} =
      Accounts.update_notification_prefs(ctx.admin, %{notify_on_backup: :every_run},
        actor: ctx.admin
      )

    erased = Accounts.anonymize_user!(every, actor: ctx.other_admin)
    assert erased.notify_on_backup == :failures
  end

  test "the data export includes it", ctx do
    assert %{notification_preferences: %{notify_on_backup: :failures}} =
             Accounts.export_user_data(ctx.admin)

    stored = %{ctx.admin | notify_on_backup: %KilnCMS.Types.UnknownAtom{value: "weekly"}}

    assert %{notification_preferences: %{notify_on_backup: "weekly"}} =
             Accounts.export_user_data(stored)
  end
end
