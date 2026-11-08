defmodule KilnCMSWeb.AuthPasswordNoticeTest do
  @moduledoc """
  The breached-password warning after register and reset (#2240). Both run
  inside upstream components that drop the action's metadata, so the action
  leaves a note (`KilnCMS.Accounts.PasswordNotice`) and the password sign-in
  that follows turns it into a flash: once, for that user, not after a magic
  link.

  `async: false`: the breach stub and the note store are node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.BreachedPasswordFixtures

  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.AuthController

  @old_password "password123456"

  defp strategy, do: AshAuthentication.Info.strategy!(User, :password)

  defp flash_conn do
    build_conn()
    |> Plug.Conn.put_private(:phoenix_endpoint, KilnCMSWeb.Endpoint)
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
  end

  defp warning, do: PasswordNotice.message()

  defp error_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error)

  defp register(password) do
    email = "notice-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy(),
        :register,
        %{"email" => email, "password" => password, "password_confirmation" => password},
        []
      )

    user
  end

  defp reset(password) do
    user =
      Ash.Seed.seed!(User, %{
        email: "notice-reset-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@old_password),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy(), user)

    {:ok, reset} =
      AshAuthentication.Strategy.action(
        strategy(),
        :reset,
        %{"reset_token" => token, "password" => password, "password_confirmation" => password},
        []
      )

    reset
  end

  defp sign_in_success(user, activity),
    do: AuthController.success(flash_conn(), activity, user, "token")

  describe "after register" do
    test "the password sign-in that follows shows the warning once" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      user = register(pw)

      # Registering is not signing in (#2255): it neither shows nor consumes
      # the note, so the warning waits for the sign-in it belongs to.
      registered = sign_in_success(user, {:password, :register})
      assert error_flash(registered) == nil
      assert Phoenix.Flash.get(registered.assigns.flash, :info)

      first = sign_in_success(user, {:password, :sign_in})
      assert error_flash(first) == warning()

      second = sign_in_success(user, {:password, :sign_in})
      assert error_flash(second) == nil
    end

    test "a clean password leaves nothing to show" do
      pw = password()
      enable!(&ok(&1, clean_body(pw)))
      user = register(pw)

      assert error_flash(sign_in_success(user, {:password, :register})) == nil
    end

    test "the sign-in-token exchange is a password sign-in too" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      user = register(pw)

      assert error_flash(sign_in_success(user, {:password, :sign_in_with_token})) == warning()
    end
  end

  describe "after reset" do
    test "the sign-in the reset ends with shows the warning once" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      user = reset(pw)

      assert error_flash(sign_in_success(user, {:password, :reset})) == warning()
      assert error_flash(sign_in_success(user, {:password, :reset})) == nil
    end
  end

  describe "who sees it" do
    test "a magic-link sign-in neither shows nor consumes it" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      user = reset(pw)

      assert error_flash(sign_in_success(user, {:magic_link, :sign_in})) == nil
      # Still waiting for the password sign-in it belongs to.
      assert error_flash(sign_in_success(user, {:password, :sign_in})) == warning()
    end

    test "another user's sign-in does not see it" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      owner = reset(pw)
      other = register(password() |> tap(&enable_clean/1))

      assert error_flash(sign_in_success(other, {:password, :sign_in})) == nil
      assert error_flash(sign_in_success(owner, {:password, :sign_in})) == warning()
    end

    test "a marker left in the session by another account is not shown to this one" do
      pw = password()
      enable_clean(pw)
      other = register(pw)

      # Account A passed the password step, then abandoned its second factor:
      # the marker is still in the session when B signs in on the same browser.
      stale = Plug.Conn.put_session(flash_conn(), :password_breach_notice, true)
      conn = AuthController.success(stale, {:password, :sign_in}, other, "token")

      assert error_flash(conn) == nil
    end

    test "a note past its TTL is not shown" do
      pw = password()
      enable!(&ok(&1, breached_body(pw, 9)))
      user = reset(pw)

      Application.put_env(:kiln_cms, PasswordNotice, ttl: 1)
      on_exit(fn -> Application.delete_env(:kiln_cms, PasswordNotice) end)
      # Re-leave it with the short TTL, then let it lapse.
      PasswordNotice.put(user.id)
      Process.sleep(40)

      assert error_flash(sign_in_success(user, {:password, :sign_in})) == nil
    end
  end

  describe "with a second factor" do
    test "the note is carried to where the sign-in completes" do
      {user, _secret} = KilnCMS.TwoFactorFixtures.enabled_user()
      {user, _token} = KilnCMS.TwoFactorFixtures.with_first_factor_token(user)
      PasswordNotice.put(user.id)

      held = sign_in_success(user, {:password, :reset})
      assert redirected_to(held) == "/sign-in/verify"
      assert get_session(held, :password_breach_notice) == true
      # Nothing is shown until the code is verified.
      assert error_flash(held) == nil
      refute PasswordNotice.take(user.id)

      # `TwoFactorController` completes through the same function, with the
      # session the first factor wrote.
      session = %{password_breach_notice: get_session(held, :password_breach_notice)}

      done =
        build_conn()
        |> Plug.Test.init_test_session(session)
        |> Phoenix.Controller.fetch_flash([])
        |> AuthController.complete_sign_in(user, "You are now signed in")

      assert error_flash(done) == warning()
      assert get_session(done, :password_breach_notice) == nil
    end

    test "a leftover marker does not survive a magic-link first factor" do
      {user, _secret} = KilnCMS.TwoFactorFixtures.enabled_user()

      conn =
        flash_conn()
        |> Plug.Conn.put_session(:password_breach_notice, true)
        |> AuthController.success({:magic_link, :sign_in}, user, "token")

      assert get_session(conn, :password_breach_notice) == nil
    end
  end

  defp enable_clean(pw), do: enable!(&ok(&1, clean_body(pw)))
end
