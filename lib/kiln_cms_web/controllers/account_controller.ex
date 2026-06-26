defmodule KilnCMSWeb.AccountController do
  @moduledoc """
  Self-service account data export (GDPR Art. 15/20, #212).

  `GET /editor/account/export.json` streams the signed-in user's own profile and
  notification preferences as a downloadable JSON file. Authenticated users only;
  the payload is scoped to `current_user`, so a request can only ever export the
  caller's own data.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts

  def export(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> text("You must be signed in to export your data.")

      user ->
        body = Jason.encode!(Accounts.export_user_data(user), pretty: true)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="kiln-account-export.json")
        )
        |> send_resp(200, body)
    end
  end
end
