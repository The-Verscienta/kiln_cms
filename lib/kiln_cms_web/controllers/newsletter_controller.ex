defmodule KilnCMSWeb.NewsletterController do
  @moduledoc """
  Public newsletter endpoints: sign-up, double-opt-in confirmation, unsubscribe.

  Confirm and unsubscribe are authorized by an opaque per-subscriber token (not
  a session), so the actions run `authorize?: false` behind token lookup —
  mirroring the preview/form public surfaces. `subscribe/2` is anonymous by
  nature and gets no authorization at all; what makes it safe is that it can
  only ever create a `:pending` row, which receives nothing until the address
  owner clicks the link mailed to them.

  Unsubscribe is split by verb so a *GET never mutates state* — an email link
  scanner/prefetcher following the footer link must not silently unsubscribe the
  reader. GET renders a one-button confirmation page; POST performs the
  unsubscribe, which is also where the RFC 8058 `List-Unsubscribe-Post` one-click
  lands. The CSRF-free `:public_form` pipeline lets that one-click POST work from
  mail clients.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Forms
  alias KilnCMS.Newsletter
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  @doc """
  `POST /newsletter/subscribe` — anonymous sign-up (issue #586).

  Form-encoded `email` (required) and `name`; the on-site form is expected to
  carry the shared honeypot input (`KilnCMS.Forms.honeypot_field/0`), whose
  presence discards the submission with a *fake success*, exactly as public form
  submissions do.

  **Every outcome renders the same page.** Whether the address was new, already
  confirmed, previously unsubscribed, or honeypotted, the response is "check
  your email" — otherwise this endpoint becomes an oracle for whether a given
  address subscribes to this site. Only a syntactically invalid address gets a
  distinct response, since that leaks nothing about anyone.

  Rate limiting is the `:form` bucket on the `:public_form` pipeline, which
  bounds how fast anyone can make us mail an address they don't own.
  """
  def subscribe(conn, params) do
    email = params |> Params.string("email", "") |> String.trim()

    cond do
      email == "" ->
        invalid(conn)

      # Honeypot tripped: report success, store nothing, mail nothing.
      params[Forms.honeypot_field()] not in [nil, ""] ->
        submitted(conn)

      true ->
        do_subscribe(conn, email, Params.string(params, "name"))
    end
  end

  defp do_subscribe(conn, email, name) do
    # Anonymous caller, so no actor: `authorize?: false` behind the tenant, like
    # the confirm/unsubscribe writes below. The site is the request's own org
    # (epic #336) — a subscriber belongs to one site.
    case Newsletter.subscribe(%{email: email, name: name},
           authorize?: false,
           tenant: Tenant.current_org_id(conn)
         ) do
      {:ok, _subscriber} ->
        submitted(conn)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        # A rejected address shape is the one failure worth telling the visitor
        # about; anything else is ours, not theirs.
        if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :email}, &1)) do
          invalid(conn)
        else
          failed(conn, errors)
        end

      {:error, error} ->
        failed(conn, List.wrap(error))
    end
  end

  # Logs the error *classes* only. `inspect/1` on an Ash error carries the
  # changeset, and with it the address someone just typed into a public form —
  # which has no business in the log aggregator (see the privacy note on
  # `KilnCMS.Mail`'s own reason redaction).
  defp failed(conn, errors) do
    classes = errors |> Enum.map(&error_class/1) |> Enum.uniq() |> Enum.join(", ")
    Logger.warning("newsletter subscribe failed: #{classes}")

    page(
      conn,
      gettext("Something went wrong"),
      gettext("We couldn't sign you up just now. Please try again shortly.")
    )
  end

  defp error_class(%struct{}), do: inspect(struct)
  defp error_class(other) when is_atom(other), do: inspect(other)
  defp error_class(_other), do: "unknown"

  defp invalid(conn),
    do:
      page(
        conn,
        gettext("Check that address"),
        gettext("That doesn't look like an email address. Please go back and try again.")
      )

  defp submitted(conn),
    do:
      page(
        conn,
        gettext("Almost there"),
        gettext(
          "Check your inbox for a confirmation link. You won't receive anything until you click it."
        )
      )

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
