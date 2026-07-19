defmodule KilnCMSWeb.TwoFactorController do
  @moduledoc """
  Second-factor (TOTP) verification after the first factor for a 2FA-enabled
  account (issue #331). Reached only via the short-lived, signed `:pending_2fa`
  token that `KilnCMSWeb.AuthController` sets — the user is not signed in until a
  valid code is entered here. Served on the `:browser_auth` pipeline (CSRF + the
  tight `:auth` rate limit slowing code brute-forcing).
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp
  alias KilnCMSWeb.AuthController

  def new(conn, _params) do
    case pending_user(conn) do
      {:ok, _user} -> render_form(conn, 200, nil)
      :error -> redirect(conn, to: ~p"/sign-in")
    end
  end

  def create(conn, %{"code" => code}) do
    with {:ok, user} <- pending_user(conn),
         {:ok, user} <- second_factor(user, code) do
      AuthController.complete_sign_in(conn, user, gettext("You are now signed in"))
    else
      :error ->
        # Pending token missing/expired — restart from sign-in.
        redirect(conn, to: ~p"/sign-in")

      :invalid ->
        render_form(conn, 401, gettext("That code isn't valid. Try again."))
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/sign-in")

  # The 6-digit TOTP — or, when the authenticator is unavailable, a one-time
  # recovery code, burned on use in the same update (#331). The consume action
  # returns a fresh record; the pending first-factor token from `pending_user/1`
  # is reattached so `complete_sign_in` can store the session.
  defp second_factor(user, code) when is_binary(code) do
    if Totp.valid?(user.totp_secret, String.trim(code)) do
      {:ok, user}
    else
      case Accounts.consume_totp_recovery_code(user, %{code: code}, authorize?: false) do
        {:ok, updated} -> {:ok, %{updated | __metadata__: user.__metadata__}}
        {:error, _} -> :invalid
      end
    end
  end

  defp second_factor(_user, _code), do: :invalid

  # Resolve the pending token to the awaiting user, or `:error` if it's
  # missing/expired/tampered or the account no longer has 2FA.
  defp pending_user(conn) do
    with pending when is_binary(pending) <- get_session(conn, :pending_2fa),
         {:ok, %{"user_id" => user_id, "token" => token}} <-
           AuthController.verify_pending(conn, pending),
         user when not is_nil(user) <-
           Accounts.get_user!(user_id, authorize?: false, not_found_error?: false),
         true <- Accounts.totp_enabled?(user) do
      # Reattach the first-factor token so `complete_sign_in` can store the
      # session (the token was already minted + stored at password sign-in).
      {:ok, %{user | __metadata__: Map.put(user.__metadata__, :token, token)}}
    else
      _ -> :error
    end
  end

  # Standalone styled page (no app shell) matching the sign-in aesthetic. Inline
  # styles only — allowed by the browser CSP; no scripts.
  # sobelow_skip ["XSS.SendResp"]
  defp render_form(conn, status, error) do
    token = Phoenix.Controller.get_csrf_token()

    error_html =
      case error do
        nil -> ""
        msg -> ~s(<p style="color:#f87171;font-size:14px;margin:0 0 12px;">#{h(msg)}</p>)
      end

    html = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{h(gettext("Two-factor authentication"))}</title>
      </head>
      <body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#1c1a17;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#ececec;">
        <main style="width:100%;max-width:360px;padding:0 24px;">
          <h1 style="font-size:20px;font-weight:600;margin:0 0 8px;">#{h(gettext("Two-factor authentication"))}</h1>
          <p style="color:#a3a3a3;font-size:14px;margin:0 0 20px;">#{h(gettext("Enter the 6-digit code from your authenticator app, or one of your recovery codes."))}</p>
          #{error_html}
          <form method="post" action="#{~p"/sign-in/verify"}">
            <input type="hidden" name="_csrf_token" value="#{h(token)}" />
            <input
              type="text" name="code" autocomplete="one-time-code"
              maxlength="12" autofocus required
              style="width:100%;box-sizing:border-box;padding:12px;font-size:18px;letter-spacing:4px;text-align:center;border-radius:10px;border:1px solid #3a352f;background:#26231f;color:#ececec;"
            />
            <button
              type="submit"
              style="width:100%;margin-top:16px;padding:12px;font-size:15px;font-weight:600;border:none;border-radius:10px;background:#c8865a;color:#1c1a17;cursor:pointer;"
            >#{h(gettext("Verify"))}</button>
          </form>
        </main>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp h(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
