defmodule KilnCMSWeb.SettingsLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp authed_user(role) do
    email = "settings-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/settings")
    end

    test "editors can load their settings", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")
      assert html =~ "Email notifications"
      assert html =~ "Review requested"
    end

    test "offers a self-service data export link (#212)", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")
      assert html =~ "Export my data"
      assert html =~ ~p"/editor/account/export.json"
    end
  end

  describe "saving preferences" do
    test "muting an event persists to the user", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      lv
      |> form("#notification-prefs-form",
        user: %{
          "notify_on_review_request" => "true",
          "notify_on_publish" => "false",
          "notify_on_return_to_draft" => "true"
        }
      )
      |> render_submit()

      reloaded = reload(user)
      assert reloaded.notify_on_review_request == true
      assert reloaded.notify_on_publish == false
      assert reloaded.notify_on_return_to_draft == true
    end
  end

  # #141: profile (display name) and password change have web UIs.
  describe "profile" do
    test "updates the display name", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/settings")
      assert html =~ "Display name"

      lv
      |> form("#profile-form", user: %{"name" => "Ada Lovelace"})
      |> render_submit()

      assert reload(user).name == "Ada Lovelace"
    end
  end

  describe "password" do
    test "changes the password with the correct current password", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/settings")
      assert html =~ "Change password"

      saved =
        lv
        |> form("#password-form",
          user: %{
            "current_password" => @password,
            "password" => "newpassword789",
            "password_confirmation" => "newpassword789"
          }
        )
        |> render_submit()

      assert saved =~ "Password changed"

      # The new password now authenticates.
      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:ok, _} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 "email" => to_string(reload(user).email),
                 "password" => "newpassword789"
               })
    end

    test "rejects a wrong current password", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      result =
        lv
        |> form("#password-form",
          user: %{
            "current_password" => "wrongpassword",
            "password" => "newpassword789",
            "password_confirmation" => "newpassword789"
          }
        )
        |> render_submit()

      assert result =~ "Couldn&#39;t change your password"
    end
  end

  describe "two-factor enrolment (#331)" do
    alias KilnCMS.Accounts
    alias KilnCMS.Accounts.RecoveryCodes
    alias KilnCMS.Accounts.Totp

    defp current_code(user),
      do: Totp.code_at(reload(user).totp_secret, System.system_time(:second))

    test "enrolment shows a QR code; confirming mints show-once recovery codes", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = live(log_in(conn, user), ~p"/editor/settings")

      lv |> element("button", "Enable two-factor authentication") |> render_click()
      html = render(lv)
      assert html =~ "totp-qr"
      assert html =~ "<svg"

      lv |> form("#confirm-totp-form", %{"code" => current_code(user)}) |> render_submit()

      # The freshly minted codes are on screen (show-once) and only hashes stored.
      html = render(lv)
      assert html =~ "recovery-codes"
      assert length(Regex.scan(~r/[A-Z2-7]{4}-[A-Z2-7]{4}/, html)) >= RecoveryCodes.count()
      assert length(reload(user).totp_recovery_hashes) == RecoveryCodes.count()

      lv |> element("button", "saved them") |> render_click()
      refute render(lv) =~ "recovery-codes"
    end

    test "regenerating replaces the set; disabling clears it", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      code = Totp.code_at(user.totp_secret, System.system_time(:second))
      {:ok, user} = Accounts.confirm_totp(user, %{code: code}, actor: user)
      original = reload(user).totp_recovery_hashes

      {:ok, lv, _html} = live(log_in(conn, user), ~p"/editor/settings")

      lv |> form("#regenerate-recovery-form", %{"code" => current_code(user)}) |> render_submit()
      regenerated = reload(user).totp_recovery_hashes
      assert length(regenerated) == RecoveryCodes.count()
      assert MapSet.disjoint?(MapSet.new(original), MapSet.new(regenerated))

      lv |> form("#disable-totp-form", %{"code" => current_code(user)}) |> render_submit()
      assert reload(user).totp_recovery_hashes == []
      assert is_nil(reload(user).totp_secret)
    end
  end
end
