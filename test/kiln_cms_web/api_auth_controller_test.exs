defmodule KilnCMSWeb.ApiAuthControllerTest do
  @moduledoc """
  Headless sign-in (`POST /api/auth/sign_in`) — exchanges credentials for a
  bearer token usable against the JSON:API / GraphQL surfaces (issue #37).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.BearerAuth

  @password "password123456"

  defp seed_user(role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp post_sign_in(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", body)
  end

  test "valid credentials return a usable bearer token + user", %{conn: conn} do
    user = seed_user(:editor)

    conn = post_sign_in(conn, %{email: to_string(user.email), password: @password})

    assert %{"token" => token, "user" => returned} = json_response(conn, 201)
    assert returned["id"] == user.id
    assert returned["email"] == to_string(user.email)
    assert returned["role"] == "editor"

    # The token authenticates as the signed-in user.
    assert {:ok, authed} = BearerAuth.user_from_token(token)
    assert authed.id == user.id
  end

  test "wrong password is a generic 401", %{conn: conn} do
    user = seed_user(:admin)

    conn = post_sign_in(conn, %{email: to_string(user.email), password: "wrong-password"})

    assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 401)
    assert detail == "Invalid email or password"
  end

  test "unknown email is the same generic 401 (no user enumeration)", %{conn: conn} do
    conn = post_sign_in(conn, %{email: "nobody@example.com", password: @password})

    assert %{"errors" => [%{"detail" => "Invalid email or password"}]} = json_response(conn, 401)
  end

  test "missing fields are a 422", %{conn: conn} do
    conn = post_sign_in(conn, %{email: "someone@example.com"})

    assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 422)
    assert detail =~ "required"
  end
end
