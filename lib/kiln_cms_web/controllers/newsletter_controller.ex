defmodule KilnCMSWeb.NewsletterController do
  @moduledoc """
  Public newsletter endpoints: double-opt-in confirmation and unsubscribe.

  Authorized by an opaque per-subscriber token (not a session), so the actions
  run `authorize?: false` behind token lookup — mirroring the preview/form
  public surfaces. The unsubscribe endpoint accepts both GET (footer link) and
  POST (RFC 8058 `List-Unsubscribe-Post` one-click); the CSRF-free `:public_form`
  pipeline makes the one-click POST work from mail clients.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Newsletter

  # GET or POST /newsletter/unsubscribe/:token
  def unsubscribe(conn, %{"token" => token}) do
    case Newsletter.subscriber_by_unsubscribe_token!(token,
           authorize?: false,
           not_found_error?: false
         ) do
      nil ->
        page(conn, gettext("Link not recognized"), gettext("This unsubscribe link is invalid."))

      subscriber ->
        {:ok, _} = Newsletter.unsubscribe_subscriber(subscriber, authorize?: false)

        page(
          conn,
          gettext("You've been unsubscribed"),
          gettext("You won't receive further newsletters at %{email}.",
            email: to_string(subscriber.email)
          )
        )
    end
  end

  # GET /newsletter/confirm/:token
  def confirm(conn, %{"token" => token}) do
    case Newsletter.subscriber_by_confirm_token!(token,
           authorize?: false,
           not_found_error?: false
         ) do
      nil ->
        page(
          conn,
          gettext("Link not recognized"),
          gettext("This confirmation link is invalid or expired.")
        )

      subscriber ->
        {:ok, _} = Newsletter.confirm_subscriber(subscriber, authorize?: false)

        page(
          conn,
          gettext("Subscription confirmed"),
          gettext("Thanks — your subscription to %{email} is confirmed.",
            email: to_string(subscriber.email)
          )
        )
    end
  end

  # A small self-contained confirmation page. Values are HTML-escaped; no scripts,
  # so the strict browser CSP applies unchanged.
  defp page(conn, heading, body) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{h(heading)}</title>
      </head>
      <body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:520px;margin:80px auto;padding:0 24px;color:#111;line-height:1.5;">
        <h1 style="font-size:22px;">#{h(heading)}</h1>
        <p style="color:#444;">#{h(body)}</p>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
