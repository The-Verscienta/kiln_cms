defmodule KilnCMSWeb.ApiAuthController do
  @moduledoc """
  Headless sign-in for API clients (issue #37).

  The browser auth flow (`KilnCMSWeb.AuthController`) is session-based and
  redirects, which is no use to a server-to-server consumer. This controller
  exchanges email + password for the AshAuthentication user **JWT**, returned as
  JSON, for use as `Authorization: Bearer <token>` against the JSON:API
  (`/api/json`) and GraphQL (`/gql`) surfaces.

  Mounted at `POST /api/auth/sign_in` behind the tight `:auth` rate-limit bucket
  (anti credential-stuffing). Failures return a generic 401 — they never reveal
  whether the email exists or the password was wrong.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts.User

  @doc """
  Exchange `email` + `password` for a bearer token.

  Body (`application/json`): `{"email": "...", "password": "..."}`.
  Success → `201 Created {"token": "<jwt>", "user": {"id", "email", "role"}}`.
  """
  def sign_in(conn, params) do
    email = params["email"]
    password = params["password"]

    with true <- is_binary(email) and is_binary(password),
         strategy = AshAuthentication.Info.strategy!(User, :password),
         {:ok, user} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{
             "email" => email,
             "password" => password
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        token: user.__metadata__.token,
        user: %{id: user.id, email: to_string(user.email), role: user.role}
      })
    else
      false -> unprocessable(conn)
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: [%{status: "401", detail: "Invalid email or password"}]})
  end

  defp unprocessable(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: [%{status: "422", detail: "email and password are required"}]})
  end
end
