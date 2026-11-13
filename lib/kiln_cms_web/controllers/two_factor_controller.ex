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

      It also owns the hold on the first-factor token (#742) — taken at the mint
      and released by `claim/1` — which is why this gate calls `claim/1` at all,
      when the single use a `:session` blob needs is the deleted session key.
    * `KilnCMS.Accounts.SecondFactor.check/2` owns charge → verify → forgive,
      so the ordering `AccountThrottle` depends on cannot be got wrong at one
      call site and right at the other.

  What is left below is genuinely this door's own: a session key, a rendered
  HTML form, and the remember-me cookie.

  ## A passkey answers the prompt too (#2247)

  An account with a passkey is offered it here, on a host where the ceremony
  can run (`KilnCMS.Accounts.WebAuthn.ceremony_host?/1`). It is a JSON
  two-step beside the form, driven by `assets/js/passkeys.js`:

    1. `POST /sign-in/verify/passkey/options` mints a challenge limited to the
       pending account's own credentials and parks it, bound to that account,
       under its own session key — never the anonymous ceremony's.
    2. `POST /sign-in/verify/passkey` takes it back (single use) for the same
       account, and `KilnCMS.Accounts.SecondFactor.check_passkey/3` verifies
       the assertion against the code's budget, alert and failure event. Then
       the same claim and completion as a code.

  Each route asks `PendingSignIn` for its own factor, so a passkey-only
  account cannot spend the shared budget on the code form, and the code
  routes are untouched for everyone else.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Security.AuthEvents
  alias KilnCMSWeb.AuthController

  # The step-up challenge's nonce. Not `PasskeyController`'s key: the two
  # ceremonies' nonces must never stand in for each other.
  @step_up_key :passkey_step_up_nonce

  def new(conn, _params) do
    case pending(conn, :any) do
      {:ok, _pending} -> render_form(conn, 200, nil)
      :error -> redirect(conn, to: ~p"/sign-in")
    end
  end

  # `:totp`: an account without the authenticator app has no code to check, so
  # it must not reach `SecondFactor.check/3` and spend the budget (#2247).
  def create(conn, %{"code" => code}) do
    with {:ok, %{user: user, remember_me?: remember_me?} = resolved} <- pending(conn, :totp),
         {:ok, user} <- SecondFactor.check(user, code, context: AuthEvents.context(conn)),
         # In the `with`, not beside it, and for the headless gate's reason
         # (#743) plus one of this door's own (#742): claiming releases the
         # first-factor token `mint_and_hold/4` held, and a session established on a token
         # still parked in the store is a sign-in that answers 401 on its very
         # next request. The `:session` blob's single use is still the deleted
         # session key — the claim half of this is a no-op here — but the release
         # half is the same on both doors, which is the point of sharing it.
         :ok <- PendingSignIn.claim(resolved) do
      conn
      # Record that THIS session was established with a recovery code (#786), so
      # a later re-enrolment on /editor/settings can promote a fresh TOTP secret
      # over the live one without a current code — the owner who lost their
      # authenticator has none to give, and the recovery code already stood in
      # for the factor. Set from the verified record's own metadata, never from
      # anything the client sent.
      |> mark_recovery_login(user)
      # Only now. The remember-me cookie is a complete sign-in in a cookie — the
      # read plug hands it straight to `store_in_session/2` — so issuing it at
      # the first factor, which is what AshAuthentication does by default, would
      # let someone tick the box, abandon this prompt, and hold a thirty-day
      # credential that never asks for a code. `AuthController.success/4`
      # withholds it there and carries the intent here instead (#699).
      |> then(&if remember_me?, do: AuthController.put_remember_me(&1, user), else: &1)
      |> AuthController.complete_sign_in(
        user,
        gettext("You are now signed in"),
        first_factor_method(conn),
        second_factor?: true
      )
    else
      # `:taken` joins it (#742): a `:session` blob never reports it, so reaching
      # it means the pending state was somehow redeemed elsewhere, and the
      # exchange is over either way.
      answer when answer in [:error, :taken] ->
        # Pending token missing/expired — restart from sign-in.
        redirect(conn, to: ~p"/sign-in")

      # The release could not be recorded, so the token this session would be
      # established on is still parked. Not `/sign-in`: the code was right and
      # the `:session` blob is still good (its claim half is a no-op), so the
      # honest answer is to try this again — the same one the headless gate
      # gives as a 503.
      #
      # One thing it costs, and it is worth knowing rather than hiding: a
      # *recovery* code is already spent by the time we get here, because
      # `SecondFactor.check/2` burns it on a successful verify. Retrying with
      # the same one will be refused. That is the price of any failure point
      # after the check, and moving the burn later would mean a code that
      # verified twice — which is the thing recovery codes must not do.
      :unavailable ->
        render_form(
          conn,
          503,
          gettext("Sign-in could not be completed right now. Try again in a moment.")
        )

      # `SecondFactor.check/2` has already alerted the owner: whoever is here
      # got past a first factor, which is news #478's alert cannot carry (it
      # could not even fire here until #742 stopped a password that stops at
      # this prompt from clearing its counter). The user comes back through the
      # tuple because a `with`'s `else` cannot see clause bindings.
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

  @doc """
  Step one of the passkey step-up (#2247): a challenge for the pending
  account's own passkeys, its nonce parked in the session. Refused alike when
  nothing is pending, the account has no passkey, or this host cannot run the
  ceremony.
  """
  def passkey_options(conn, _params) do
    with true <- WebAuthn.ceremony_host?(conn.host),
         {:ok, %{user: user}} <- pending(conn, :passkey) do
      challenge = WebAuthn.step_up_challenge(user)

      # As on the anonymous ceremony: the challenge parks server-side, single
      # use, and only an opaque nonce rides the session — here bound to the
      # account it was minted for.
      conn
      |> put_session(@step_up_key, WebAuthn.stash_step_up_challenge(challenge, user.id))
      |> json(%{publicKey: WebAuthn.step_up_options(challenge)})
    else
      _refused -> passkey_refused(conn)
    end
  end

  @doc """
  Step two of the passkey step-up (#2247): verify the assertion as this
  pending sign-in's second factor and complete it, answering JSON
  `{redirect_to}` for the script to follow.
  """
  def passkey_verify(conn, params) do
    nonce = get_session(conn, @step_up_key)
    conn = delete_session(conn, @step_up_key)

    with {:ok, %{user: user, remember_me?: remember_me?} = resolved} <- pending(conn, :passkey),
         # Bound to the account: a nonce parked for another pending sign-in,
         # or by the anonymous ceremony, is no challenge here.
         %Wax.Challenge{} = challenge <- WebAuthn.take_step_up_challenge(nonce, user.id),
         {:ok, user} <-
           SecondFactor.check_passkey(user, {challenge, params},
             context: AuthEvents.context(conn)
           ),
         # The code's reason (#742, #743): the claim releases the held
         # first-factor token, so a session established before it would be
         # signed out on its next request.
         :ok <- PendingSignIn.claim(resolved) do
      # The remember-me cookie only now, for the code's reason (#699).
      conn = if remember_me?, do: AuthController.put_remember_me(conn, user), else: conn

      {conn, return_to} =
        AuthController.establish_session(
          conn,
          user,
          gettext("You are now signed in"),
          first_factor_method(conn),
          second_factor?: true
        )

      json(conn, %{redirect_to: return_to})
    else
      :unavailable ->
        conn
        |> put_status(503)
        |> json(%{
          error: gettext("Sign-in could not be completed right now. Try again in a moment.")
        })

      {:deny, _user, retry_after_ms} ->
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(AccountThrottle.retry_after_seconds(retry_after_ms))
        )
        |> put_status(429)
        |> json(%{error: gettext("Too many attempts. Wait a few minutes and try again.")})

      # Nothing pending, no passkey, no challenge for this account, a refused
      # assertion, or `:taken`: one answer. A refused assertion was already
      # recorded and charged by `SecondFactor.check_passkey/3`.
      _refused ->
        passkey_refused(conn)
    end
  end

  defp passkey_refused(conn) do
    conn
    |> put_status(401)
    |> json(%{
      error: gettext("That passkey couldn't be verified. Try again or use another method.")
    })
  end

  # How the first factor was passed, for the sign-in event and the session
  # marker; `AuthController.success/4` parked it beside `:pending_2fa`.
  defp first_factor_method(conn), do: get_session(conn, :sign_in_method) || "password"

  # `SecondFactor.check/2` stamps which factor it accepted; only a recovery-code
  # sign-in marks the session (#786). Kept for the session's lifetime — it does
  # not weaken anything on its own; it only lets `:confirm_totp` waive the
  # current-code proof for someone who provably had no live code.
  defp mark_recovery_login(conn, user) do
    if Ash.Resource.get_metadata(user, :second_factor_method) == :recovery,
      do: put_session(conn, "totp_recovery_login", true),
      else: conn
  end

  # The session key is this gate's only difference from the headless one; the
  # blob itself — its lifetime, its payload, the four steps that turn it back
  # into a user — is `PendingSignIn`'s business for both (#745).
  defp pending(conn, factor) do
    PendingSignIn.resolve(:session, conn, get_session(conn, :pending_2fa), factor)
  end

  # `KilnCMSWeb.TwoFactorHTML` in `Layouts.auth/1` (#1676) — the same shell as
  # `/sign-in`, so the page gets its brand row, both themes and a `lang` from
  # the request's locale from the root layout rather than restating them. The
  # root layout comes from `:browser_auth`, which also sets this page's CSP;
  # nothing here adds a script, so that policy is unchanged.
  #
  # `factor` only chooses which of the two fields the page reopens on; the
  # code itself is checked exactly as before, whichever form sent it.
  #
  # Which factors the page offers is the pending account's (#2247): the code
  # fields only with the authenticator app, the passkey only with a passkey and
  # on a host where its ceremony can run. A blob that no longer resolves keeps
  # the code form, which answers it by sending the caller back to `/sign-in`.
  defp render_form(conn, status, error) do
    factors =
      case pending(conn, :any) do
        {:ok, %{factors: factors}} -> factors
        :error -> %{totp?: true, passkeys: 0}
      end

    conn
    |> put_status(status)
    |> put_layout(html: {KilnCMSWeb.Layouts, :auth})
    |> put_view(html: KilnCMSWeb.TwoFactorHTML)
    |> render(:new,
      page_title: gettext("Two-factor authentication"),
      error: error,
      recovery?: conn.params["factor"] == "recovery",
      code?: factors.totp?,
      passkey?: factors.passkeys > 0 and WebAuthn.ceremony_host?(conn.host)
    )
  end
end
