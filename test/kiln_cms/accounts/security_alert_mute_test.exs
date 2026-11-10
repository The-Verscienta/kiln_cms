defmodule KilnCMS.Accounts.SecurityAlertMuteTest do
  @moduledoc """
  `User.notify_on_security_alert` (#2245): on by default, visible to the
  account holder and platform admins only, and changeable by the account holder
  alone — a platform admin, who may edit anyone's other notification
  preferences, cannot mute someone else's security alerts.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "mute-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    %{admin: user(:admin), editor: user(:editor), viewer: user(:viewer)}
  end

  test "on by default, and the account holder and platform admins see it", ctx do
    assert ctx.editor.notify_on_security_alert == true

    assert {:ok, %{notify_on_security_alert: true}} =
             Accounts.get_user(ctx.editor.id, actor: ctx.editor)

    assert {:ok, %{notify_on_security_alert: true}} =
             Accounts.get_user(ctx.editor.id, actor: ctx.admin)
  end

  test "the account holder can turn it off and on", ctx do
    assert {:ok, %{notify_on_security_alert: false} = muted} =
             Accounts.update_notification_prefs(ctx.editor, %{notify_on_security_alert: false},
               actor: ctx.editor
             )

    assert {:ok, %{notify_on_security_alert: true}} =
             Accounts.update_notification_prefs(muted, %{notify_on_security_alert: true},
               actor: ctx.editor
             )
  end

  test "a platform admin cannot mute another account's alerts, but can edit its other prefs",
       ctx do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Accounts.update_notification_prefs(ctx.editor, %{notify_on_security_alert: false},
               actor: ctx.admin
             )

    assert Exception.message(error) =~ "account holder"

    assert {:ok, %{notify_on_comment: false, notify_on_security_alert: true}} =
             Accounts.update_notification_prefs(ctx.editor, %{notify_on_comment: false},
               actor: ctx.admin
             )
  end

  test "another non-admin cannot change it", ctx do
    # Refused by the validation before the policy is asked; either is a refusal.
    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.update_notification_prefs(ctx.editor, %{notify_on_security_alert: false},
               actor: ctx.viewer
             )

    assert {:ok, %{notify_on_security_alert: true}} =
             Accounts.get_user(ctx.editor.id, actor: ctx.editor)
  end

  test "a platform admin can mute their own", ctx do
    assert {:ok, %{notify_on_security_alert: false}} =
             Accounts.update_notification_prefs(ctx.admin, %{notify_on_security_alert: false},
               actor: ctx.admin
             )
  end
end
