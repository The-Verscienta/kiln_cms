defmodule KilnCMSWeb.SettingsLiveDemoTest do
  @moduledoc """
  `/editor/settings` in demo mode (`docs/demo-mode.md`): the shared account's
  password, two-factor and passkey controls give way to a note saying why, and
  an event sent anyway surfaces the action's refusal as that same sentence.
  The refusal itself lives on the actions —
  `KilnCMS.Accounts.DemoCredentialsLockTest`.

  `async: false`: `Application.put_env` is a process-wide write.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"
  @note "This is a shared demo account, so its password and sign-in methods can't be changed."

  setup do
    saved = Application.get_env(:kiln_cms, KilnCMS.Demo)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:kiln_cms, KilnCMS.Demo, saved),
        else: Application.delete_env(:kiln_cms, KilnCMS.Demo)
    end)

    Application.put_env(:kiln_cms, KilnCMS.Demo, enabled: true)
    :ok
  end

  defp authed_user(role) do
    email = "settings-demo-#{System.unique_integer([:positive])}@example.com"

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

  defp open(conn, user) do
    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/settings")

    lv
  end

  # The text of every demo note on the page, whitespace-collapsed.
  defp notes(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(~s([data-role="demo-locked"]))
    |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))
  end

  defp flash_error(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#flash-error")
    |> Floki.text()
  end

  test "an editor sees a note in place of the password, two-factor and passkey forms",
       %{conn: conn} do
    lv = open(conn, authed_user(:editor))

    assert notes(lv) == [@note, @note, @note]
    refute has_element?(lv, "#password-form")
    refute has_element?(lv, ~s(button[phx-click="start_totp"]))
    refute has_element?(lv, "#add-passkey-form")
    # Everything else on the page is untouched.
    assert has_element?(lv, "#profile-form")
    assert has_element?(lv, "#notification-prefs-form")
  end

  test "an admin keeps every form", %{conn: conn} do
    lv = open(conn, authed_user(:admin))

    assert notes(lv) == []
    assert has_element?(lv, "#password-form")
    assert has_element?(lv, ~s(button[phx-click="start_totp"]))
    assert has_element?(lv, "#add-passkey-form")
  end

  test "a password change sent anyway is refused with the note", %{conn: conn} do
    lv = open(conn, authed_user(:editor))

    render_hook(lv, "save_password", %{
      "user" => %{
        "current_password" => @password,
        "password" => "a-new-password-9876",
        "password_confirmation" => "a-new-password-9876"
      }
    })

    assert flash_error(lv) =~ @note
  end

  test "a two-factor enrolment sent anyway is refused with the note", %{conn: conn} do
    lv = open(conn, authed_user(:editor))

    render_hook(lv, "start_totp", %{})

    assert flash_error(lv) =~ @note
  end

  test "a passkey enrolment is refused before the browser prompt", %{conn: conn} do
    lv = open(conn, authed_user(:editor))

    render_hook(lv, "passkey_begin", %{"name" => "Laptop"})

    assert flash_error(lv) =~ @note
    refute_push_event(lv, "passkey-register", %{})
  end
end
