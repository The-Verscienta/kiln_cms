defmodule KilnCMSWeb.DemoResetGateTest do
  @moduledoc """
  While a demo reset runs, a signed-in LiveView refuses to mount and sends the
  visitor to sign-in (`KilnCMSWeb.LiveUserAuth`, `docs/demo-mode.md`). The
  reset evicts every socket just before it restores; a reconnect that mounted
  would hold pre-reset data, and its autosave would land in the restored
  tables once the restore's locks were released.
  """
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Demo.LiveState

  @password "password123456"

  setup do
    on_exit(fn -> LiveState.end_local() end)
    :ok
  end

  defp editor do
    email = "demo-gate-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  test "a signed-in page refuses to mount during a reset and says why", %{conn: conn} do
    user = editor()
    LiveState.begin_local()

    assert {:error,
            {:redirect,
             %{
               to: "/sign-in",
               flash: %{"info" => "The demo is being reset. Sign in again in a moment."}
             }}} = conn |> log_in(user) |> live(~p"/editor/overview")
  end

  test "the same page mounts again once the reset has ended", %{conn: conn} do
    user = editor()
    LiveState.begin_local()
    LiveState.end_local()

    assert {:ok, _lv, _html} = conn |> log_in(user) |> live(~p"/editor/overview")
  end
end
