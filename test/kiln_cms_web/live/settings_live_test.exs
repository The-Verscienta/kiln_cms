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

  # Usability pass, M5: the nav calls this screen "Your settings" and site
  # configuration lives in the Configure hub, so a page titled plain "Settings"
  # sent people looking for site settings to the wrong place.
  describe "naming" do
    test "the page is titled Your settings, like the nav", %{conn: conn} do
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")

      assert has_element?(lv, "h1", "Your settings")
      assert html =~ ~r/<title[^>]*>\s*Your settings/
    end
  end

  describe "the sidebar preset" do
    test "offers both presets and marks the current one", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/settings")

      assert has_element?(lv, ~s(#settings-nav-preset-essentials[aria-pressed="true"]))
      assert has_element?(lv, ~s(#settings-nav-preset-everything[aria-pressed="false"]))
    end

    test "choosing Everything saves it and redraws the sidebar", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      refute has_element?(lv, ~s(aside a.side-link[href="/editor/taxonomy"]))

      lv |> element("#settings-nav-preset-everything") |> render_click()

      assert reload(user).nav_preset == :everything
      assert has_element?(lv, ~s(#settings-nav-preset-everything[aria-pressed="true"]))
      assert has_element?(lv, ~s(aside a.side-link[href="/editor/taxonomy"]))
      assert has_element?(lv, "aside #nav-preset-switch", "Show essentials")
    end
  end

  describe "the content list's status marks" do
    test "words are the default", %{conn: conn} do
      user = authed_user(:editor)
      assert user.status_marks == :words

      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      assert has_element?(lv, ~s(#settings-status-marks-words[aria-pressed="true"]))
      assert has_element?(lv, ~s(#settings-status-marks-trigrams[aria-pressed="false"]))
    end

    test "opting into trigram glyphs saves it, and words switch it back", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      lv |> element("#settings-status-marks-trigrams") |> render_click()

      assert reload(user).status_marks == :trigrams
      assert has_element?(lv, ~s(#settings-status-marks-trigrams[aria-pressed="true"]))

      lv |> element("#settings-status-marks-words") |> render_click()

      assert reload(user).status_marks == :words
      assert has_element?(lv, ~s(#settings-status-marks-words[aria-pressed="true"]))
    end

    test "an unknown value is ignored", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/settings")

      render_click(lv, "set_status_marks", %{"marks" => "bagua"})

      assert reload(user).status_marks == :words
    end

    test "one account cannot set another's", %{conn: _conn} do
      user = authed_user(:editor)
      other = authed_user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.Accounts.set_status_marks(user, :trigrams, actor: other)
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

    # #1652. `log_out_everywhere` revokes the stored tokens, but a mounted
    # LiveView authorized once, at connect, and kept working until reconnect.
    # A socket is dropped by a "disconnect" broadcast on its session's
    # `live_socket_id` (Phoenix closes the transport on it), so this asserts on
    # the id sign-in writes into THIS session (`put_live_socket_id/2`, as
    # `complete_sign_in/3` does), not on a topic name recomputed from the user.
    test "changing the password drops the session's live sockets", %{conn: conn} do
      user = authed_user(:editor)
      conn = conn |> log_in(user) |> KilnCMSWeb.AuthController.put_live_socket_id(user)
      socket_id = get_session(conn, :live_socket_id)
      assert is_binary(socket_id)

      {:ok, lv, _html} = live(conn, ~p"/editor/settings")
      KilnCMSWeb.Endpoint.subscribe(socket_id)

      lv
      |> form("#password-form",
        user: %{
          "current_password" => @password,
          "password" => "newpassword789",
          "password_confirmation" => "newpassword789"
        }
      )
      |> render_submit()

      assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}, 2_000
    end

    test "a refused password change drops nothing", %{conn: conn} do
      user = authed_user(:editor)
      conn = conn |> log_in(user) |> KilnCMSWeb.AuthController.put_live_socket_id(user)
      socket_id = get_session(conn, :live_socket_id)

      {:ok, lv, _html} = live(conn, ~p"/editor/settings")
      KilnCMSWeb.Endpoint.subscribe(socket_id)

      lv
      |> form("#password-form",
        user: %{
          "current_password" => "wrongpassword",
          "password" => "newpassword789",
          "password_confirmation" => "newpassword789"
        }
      )
      |> render_submit()

      refute_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}, 200
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
    alias KilnCMS.TwoFactorFixtures

    # `current_code/1` takes the user and prefers the PENDING secret, which is
    # what a mid-enrolment test needs — asking for `totp_secret` there produces a
    # code for the factor being replaced.
    defp current_code(user), do: TwoFactorFixtures.current_code(reload(user))

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
      code = TwoFactorFixtures.current_code(user.totp_pending_secret)
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

    # #1675. Someone who signed in with a recovery code has usually lost the
    # authenticator, so the disable/regenerate forms (both ask for a live code)
    # are a dead end. The backend already waives the outgoing factor for a
    # recovery-code session (#786); this is the UI that reaches it.
    test "after a recovery-code sign-in, a new authenticator can be enrolled", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      code = TwoFactorFixtures.current_code(user.totp_pending_secret)
      {:ok, user} = Accounts.confirm_totp(user, %{code: code}, actor: user)
      old_secret = reload(user).totp_secret

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{"totp_recovery_login" => true})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)

      {:ok, lv, html} = live(conn, ~p"/editor/settings")
      assert html =~ "You signed in with a recovery code."

      lv |> element("button", "Set up a new authenticator") |> render_click()
      html = render(lv)
      assert html =~ "totp-qr"
      # The enabled-state forms step aside while the new factor is enrolled.
      refute has_element?(lv, "#disable-totp-form")

      # No current code: the one thing this user cannot produce.
      lv |> form("#confirm-totp-form", %{"code" => current_code(user)}) |> render_submit()

      assert render(lv) =~ "Two-factor authentication is now on."
      new_secret = reload(user).totp_secret
      refute is_nil(new_secret)
      refute new_secret == old_secret
    end

    test "an ordinary sign-in is not offered re-enrolment", %{conn: conn} do
      user = authed_user(:editor)
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      code = TwoFactorFixtures.current_code(user.totp_pending_secret)
      {:ok, user} = Accounts.confirm_totp(user, %{code: code}, actor: user)

      {:ok, lv, html} = live(log_in(conn, user), ~p"/editor/settings")
      refute html =~ "You signed in with a recovery code."
      refute has_element?(lv, "button", "Set up a new authenticator")
    end

    # #727. The budget is only half the fix: a spent budget that reports "that
    # code isn't valid" sends a user to type five more codes into a bucket with
    # nothing left, which is the opposite of the advice they need. The wiring
    # from `SecondFactorThrottled` to the flash is what makes the difference
    # visible, and it is one pattern match away from silently falling back.
    test "a spent budget says so, rather than blaming the code", %{conn: conn} do
      alias KilnCMS.Accounts.AccountThrottle

      user = authed_user(:editor)
      {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)
      code = TwoFactorFixtures.current_code(user.totp_pending_secret)
      {:ok, user} = Accounts.confirm_totp(user, %{code: code}, actor: user)

      {:ok, lv, _html} = live(log_in(conn, user), ~p"/editor/settings")

      # Spend the real budget from outside the LiveView, so this asserts on the
      # message rather than on the number. In one charge rather than a loop of
      # single ones: the test env raises this budget to a million, and since
      # #1619 each charge is a database round trip.
      budget =
        Application.get_env(:kiln_cms, AccountThrottle, [])[:second_factor_budget] ||
          AccountThrottle.defaults()[:second_factor_budget]

      window =
        Application.get_env(:kiln_cms, AccountThrottle, [])[:second_factor_window] ||
          AccountThrottle.defaults()[:second_factor_window]

      KilnCMS.Accounts.ThrottleStore.hit(
        "2fa",
        AccountThrottle.digest(user.id),
        window,
        budget,
        budget
      )

      assert {:deny, _} = AccountThrottle.consume_second_factor(user.id)

      # Submitting a *correct* code: the throttle is what refuses it, so a
      # "check your authenticator" message would be plainly wrong.
      html =
        lv |> form("#disable-totp-form", %{"code" => current_code(user)}) |> render_submit()

      assert html =~ "Too many attempts"
      refute html =~ "isn&#39;t valid"
      # ...and it really was refused.
      refute is_nil(reload(user).totp_secret)

      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)
    end
  end
end
