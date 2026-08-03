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

  ## This is one of two doors, and almost nothing here is door-specific (#745)

  `KilnCMSWeb.ApiAuthController` runs the same step headlessly at
  `POST /api/auth/sign_in/verify`. Both charge the *same* per-account bucket —
  a budget an attacker can double by alternating endpoints is not a budget —
  and both reach it through the same two functions:

    * `KilnCMS.Accounts.PendingSignIn` owns the blob: minting it, the
      five-minute lifetime, and the four steps that turn it back into a user.
      This gate differs only in passing `:session`, because its blob lives in
      the session rather than in the client's hands.
    * `KilnCMS.Accounts.SecondFactor.check/2` owns charge → verify → forgive,
      so the ordering `AccountThrottle` depends on cannot be got wrong at one
      call site and right at the other.

  What is left below is genuinely this door's own: a session key, a rendered
  HTML form, and the remember-me cookie.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMSWeb.AuthController

  def new(conn, _params) do
    case pending(conn) do
      {:ok, _pending} -> render_form(conn, 200, nil)
      :error -> redirect(conn, to: ~p"/sign-in")
    end
  end

  def create(conn, %{"code" => code}) do
    with {:ok, %{user: user, remember_me?: remember_me?}} <- pending(conn),
         {:ok, user} <- SecondFactor.check(user, code) do
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

      # `SecondFactor.check/2` has already alerted the owner: whoever is here
      # got past a first factor, and #478's alert structurally cannot fire in
      # this scenario (re-running that step to mint a fresh pending token
      # *succeeds*, which forgives the sign-in counter). The user comes back
      # through the tuple because a `with`'s `else` cannot see clause bindings.
      {:deny, _user, retry_after_ms} ->
        # The pending token is left in the session rather than cleared — the
        # caller has not failed authentication, so bouncing them to `/sign-in`
        # would be the wrong answer to "you have tried too often". It will not
        # usually outlive the wait: `PendingSignIn.max_age/0` is five minutes and
        # this window is fifteen, so a refused user will normally re-enter their
        # password and land back here. That is fine and is the point — the
        # budget keys on the account, so a fresh token does not refill it.
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(AccountThrottle.retry_after_seconds(retry_after_ms))
        )
        |> render_form(429, gettext("Too many attempts. Wait a few minutes and try again."))

      :invalid ->
        render_form(conn, 401, gettext("That code isn't valid. Try again."))
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/sign-in")

  # The session key is this gate's only difference from the headless one; the
  # blob itself — its lifetime, its payload, the four steps that turn it back
  # into a user — is `PendingSignIn`'s business for both (#745).
  defp pending(conn) do
    PendingSignIn.resolve(:session, conn, get_session(conn, :pending_2fa))
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
