defmodule KilnCMSWeb.TwoFactorController do
  @moduledoc """
  Second-factor (TOTP) verification after the first factor for a 2FA-enabled
  account (issue #331). Reached only via the short-lived, signed `:pending_2fa`
  token that `KilnCMSWeb.AuthController` sets — the user is not signed in until a
  valid code is entered here. Served on the `:browser_auth` pipeline (CSRF + the
  tight `:auth` rate limit slowing code brute-forcing).

  ## The per-IP limit is not the bound that matters here (#714)

  `:auth` keys strictly on the client address, which is the axis #478 established
  an attacker escapes by rotating addresses. That mattered less for the password,
  which is not enumerable; it matters a great deal for six digits and a skew
  window. So every submitted code is charged
  `KilnCMS.Accounts.AccountThrottle.consume_second_factor/1`, keyed on the
  pending account, and a verified code clears the counter.

  Charged **before** the code is checked, not after a failure, for the reason
  `AccountThrottle`'s moduledoc gives about check-then-count: a burst of
  simultaneous submissions would otherwise all read "under budget" and all get a
  full verification.

  The refusal is a plain 429 that says so, rather than the generic "that code
  isn't valid" a wrong code gets. Everywhere else in the auth flow a refusal is
  deliberately indistinguishable, because the alternative leaks whether an
  account exists — here the account is already known to whoever is asking (they
  hold a signed pending token naming it), so hiding the throttle buys nothing
  and costs a legitimate user, who is told their correct code was wrong.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Totp
  alias KilnCMSWeb.AuthController

  def new(conn, _params) do
    case pending_user(conn) do
      {:ok, _user, _remember_me?} -> render_form(conn, 200, nil)
      :error -> redirect(conn, to: ~p"/sign-in")
    end
  end

  def create(conn, %{"code" => code}) do
    with {:ok, user, remember_me?} <- pending_user(conn),
         :allow <- AccountThrottle.consume_second_factor(user.id),
         {:ok, user} <- second_factor(user, code) do
      AccountThrottle.forgive_second_factor(user.id)

      conn
      # Only now. The remember-me cookie is a complete sign-in in a cookie — the
      # read plug hands it straight to `store_in_session/2` — so issuing it at
      # the first factor, which is what AshAuthentication does by default, would
      # let someone tick the box, abandon this prompt, and hold a thirty-day
      # credential that never asks for a code. `AuthController.success/4`
      # withholds it there and carries the intent here instead (#699).
      |> then(&if remember_me?, do: AuthController.put_remember_me(&1, user), else: &1)
      |> AuthController.complete_sign_in(user, gettext("You are now signed in"))
    else
      :error ->
        # Pending token missing/expired — restart from sign-in.
        redirect(conn, to: ~p"/sign-in")

      {:deny, retry_after_ms} ->
        # The pending token is left in the session rather than cleared — the
        # caller has not failed authentication, so bouncing them to `/sign-in`
        # would be the wrong answer to "you have tried too often". It will not
        # usually outlive the wait: `@pending_2fa_max_age` is five minutes and
        # this window is fifteen, so a refused user will normally re-enter their
        # password and land back here. That is fine and is the point — the
        # budget keys on the account, so a fresh token does not refill it.
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000)))
        |> render_form(429, gettext("Too many attempts. Wait a few minutes and try again."))

      :invalid ->
        render_form(conn, 401, gettext("That code isn't valid. Try again."))
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/sign-in")

  # The 6-digit TOTP — or, when the authenticator is unavailable, a one-time
  # recovery code, burned on use in the same update (#331). The consume action
  # returns a fresh record; the pending first-factor token from `pending_user/1`
  # is reattached so `complete_sign_in` can store the session.
  #
  # Inner whitespace is stripped, not just trimmed. Authenticator apps display
  # the code as `123 456`, and Safari's `autocomplete="one-time-code"` fill and
  # a plain paste both carry that space through. Before the budget existed that
  # cost a retry; now it costs one of five, so three pastes and one genuine
  # clock-skew miss would lock a user out for fifteen minutes without their ever
  # having entered a wrong code. (The recovery-code path already normalizes case
  # and separators for the same reason — see `RecoveryCodes`.)
  defp second_factor(user, code) when is_binary(code) do
    if Totp.valid?(user.totp_secret, String.replace(code, ~r/\s/u, "")) do
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
         {:ok, %{"user_id" => user_id, "token" => token} = payload} <-
           AuthController.verify_pending(conn, pending),
         user when not is_nil(user) <-
           Accounts.get_user!(user_id, authorize?: false, not_found_error?: false),
         true <- Accounts.totp_enabled?(user) do
      # Reattach the first-factor token so `complete_sign_in` can store the
      # session (the token was already minted + stored at password sign-in).
      #
      # `remember_me` defaults to false rather than being required, so a pending
      # token minted before this shipped — or by any other caller of
      # `sign_pending/4` — degrades to "no cookie" rather than to a crash.
      {:ok, %{user | __metadata__: Map.put(user.__metadata__, :token, token)},
       payload["remember_me"] == true}
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
