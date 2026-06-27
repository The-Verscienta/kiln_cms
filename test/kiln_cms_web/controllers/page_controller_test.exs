defmodule KilnCMSWeb.PageControllerTest do
  use KilnCMSWeb.ConnCase

  alias KilnCMS.Accounts.User

  defp user(role) do
    email = "page-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123456"
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Model content once"
    assert html_response(conn, 200) =~ "KilnCMS"
  end

  # #142: viewer-role accounts (the self-registration default) get onboarding
  # copy explaining that editor access requires an admin upgrade.
  test "a viewer sees onboarding about needing an editor upgrade", %{conn: conn} do
    html = conn |> log_in(user(:viewer)) |> get(~p"/") |> html_response(200)

    assert html =~ "signed in as a viewer"
    assert html =~ "upgrade your account"
  end

  test "an editor sees the editor CTA and not the viewer onboarding", %{conn: conn} do
    html = conn |> log_in(user(:editor)) |> get(~p"/") |> html_response(200)

    refute html =~ "signed in as a viewer"
    assert html =~ "Open editor"
  end
end
