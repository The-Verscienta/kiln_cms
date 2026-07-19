defmodule KilnCMSWeb.NewsletterController do
  @moduledoc """
  Public newsletter endpoints: double-opt-in confirmation and unsubscribe.

  Authorized by an opaque per-subscriber token (not a session), so the actions
  run `authorize?: false` behind token lookup — mirroring the preview/form
  public surfaces.

  Unsubscribe is split by verb so a *GET never mutates state* — an email link
  scanner/prefetcher following the footer link must not silently unsubscribe the
  reader. GET renders a one-button confirmation page; POST performs the
  unsubscribe, which is also where the RFC 8058 `List-Unsubscribe-Post` one-click
  lands. The CSRF-free `:public_form` pipeline lets that one-click POST work from
  mail clients.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Newsletter

  # GET /newsletter/unsubscribe/:token — a confirmation page only (no state
  # change). The button POSTs to `unsubscribe/2` below.
  def unsubscribe_form(conn, %{"token" => token}) do
    case lookup(token) do
      nil ->
        page(conn, gettext("Link not recognized"), gettext("This unsubscribe link is invalid."))

      subscriber ->
        confirm_form(conn, subscriber, token)
    end
  end

  # POST /newsletter/unsubscribe/:token — the actual unsubscribe. Reached by the
  # confirmation button and by the RFC 8058 one-click.
  def unsubscribe(conn, %{"token" => token}) do
    case lookup(token) do
      nil ->
        page(conn, gettext("Link not recognized"), gettext("This unsubscribe link is invalid."))

      subscriber ->
        # The token lookup spans orgs (the token is the secret); the update runs
        # under the found subscriber's own site (epic #336).
        {:ok, _} =
          Newsletter.unsubscribe_subscriber(subscriber,
            authorize?: false,
            tenant: subscriber.org_id
          )

        page(
          conn,
          gettext("You've been unsubscribed"),
          gettext("You won't receive further newsletters at %{email}.",
            email: to_string(subscriber.email)
          )
        )
    end
  end

  defp lookup(token),
    do:
      Newsletter.subscriber_by_unsubscribe_token!(token,
        authorize?: false,
        not_found_error?: false
      )

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
        {:ok, _} =
          Newsletter.confirm_subscriber(subscriber, authorize?: false, tenant: subscriber.org_id)

        page(
          conn,
          gettext("Subscription confirmed"),
          gettext("Thanks — your subscription to %{email} is confirmed.",
            email: to_string(subscriber.email)
          )
        )
    end
  end

  # The one-button "confirm unsubscribe" page the GET link renders. No CSRF token
  # is needed (the :public_form pipeline is CSRF-free and the per-subscriber token
  # is the secret). Values are HTML-escaped.
  # sobelow_skip ["XSS.SendResp"]
  defp confirm_form(conn, subscriber, token) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{h(gettext("Unsubscribe"))}</title>
      </head>
      <body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:520px;margin:80px auto;padding:0 24px;color:#111;line-height:1.5;">
        <h1 style="font-size:22px;">#{h(gettext("Unsubscribe"))}</h1>
        <p style="color:#444;">
          #{h(gettext("Stop sending newsletters to %{email}?", email: to_string(subscriber.email)))}
        </p>
        <form method="post" action="#{~p"/newsletter/unsubscribe/#{token}"}">
          <button type="submit" style="padding:10px 16px;font-size:15px;border:none;border-radius:8px;background:#c8865a;color:#1c1a17;cursor:pointer;">
            #{h(gettext("Yes, unsubscribe"))}
          </button>
        </form>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  # A small self-contained confirmation page. Values are HTML-escaped; no scripts,
  # so the strict browser CSP applies unchanged.
  # sobelow_skip ["XSS.SendResp"]
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
