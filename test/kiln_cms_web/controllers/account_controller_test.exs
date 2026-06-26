defmodule KilnCMSWeb.AccountControllerTest do
  @moduledoc """
  Self-service data export (#212): a signed-in user downloads their own profile
  and notification preferences as JSON; anonymous requests are rejected.
  """
  use KilnCMSWeb.ConnCase, async: true

  @password "password123456"

  defp signed_in_user do
    email = "export-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      name: "Export Me",
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  test "exports the signed-in user's own data as a JSON download", %{conn: conn} do
    user = signed_in_user()

    conn = conn |> log_in(user) |> get(~p"/editor/account/export.json")

    assert response_content_type(conn, :json)

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="kiln-account-export.json")
           ]

    body = Jason.decode!(response(conn, 200))
    assert body["account"]["name"] == "Export Me"
    assert body["account"]["id"] == user.id
    refute Map.has_key?(body["account"], "hashed_password")
  end

  test "rejects an anonymous request", %{conn: conn} do
    conn = get(conn, ~p"/editor/account/export.json")
    assert conn.status == 401
  end
end
