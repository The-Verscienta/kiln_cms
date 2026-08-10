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

  ## Two-factor accounts finish at a second step (#726)

  A password alone used to return a full JWT here even for an account with TOTP
  enabled, while the browser flow diverted to `/sign-in/verify`. That made the
  second factor optional in practice rather than in policy: an attacker holding a
  stuffed password had no need to grind six digits at the prompt #714 bounds,
  because there was a door next to it that did not ask. Every mitigation on the
  second factor is worth what the weakest path that skips it is worth.

  So the headless flow now mirrors the browser one:

    1. `POST /api/auth/sign_in` with correct credentials for a 2FA account
       answers **200** `{"two_factor_required": true, "pending_token": …}`
       instead of **201** with a token. **No JWT is returned.**
    2. `POST /api/auth/sign_in/verify` exchanges that pending token plus a TOTP
       or recovery code for the **201** the first step used to give.

  An account *without* a second factor is unchanged — one call, 201, token.

  "Returned", not "issued": `Strategy.action/3` mints and — because `User` sets
  `store_all_tokens?` — *stores* the first-factor JWT before this controller
  gets to look at `totp_enabled?`. What the second factor withholds is the
  caller's access to it. Since #742 it also withholds its *use*:
  `PendingSignIn.mint/4` parks the stored row off the purpose authentication
  requires, and `claim/1` puts it back once the code lands, so an abandoned
  exchange leaves an inert row that expires with the step rather than a live
  credential nobody holds.

  The blob itself is `KilnCMS.Accounts.PendingSignIn`'s business — encrypted
  rather than signed because it carries that JWT, and single-use so a captured
  verify request cannot be replayed. Its moduledoc has the reasoning.

  ## The second step shares the second factor's budget

  Every submitted code is charged `AccountThrottle.consume_second_factor/1`,
  keyed on the account named by the pending token — the same bucket
  `KilnCMSWeb.TwoFactorController` charges, deliberately, so the six-digit space
  is bounded across *both* surfaces rather than per-surface. A budget an attacker
  can double by alternating endpoints is not a budget.

  Charged **before** the code is checked, for the reason `AccountThrottle`'s
  moduledoc gives about check-then-count, and refunded on a verified code.

  ## What the responses do and do not reveal

  `two_factor_required` tells the caller that this account has a second factor —
  but only *after* they have supplied the correct password, which the browser
  flow discloses just as plainly by redirecting to the code prompt. Before that
  point every refusal here is still the same generic 401.

  Past the password the refusals are specific — an expired pending token, a wrong
  code and a spent budget each say so — because at that point the account is
  known to whoever is asking (they hold a token naming it), so hiding the
  difference buys nothing and costs a legitimate client, which would have to
  guess whether to retry the code or restart the exchange. Each carries a stable
  `code` for exactly that decision.

  ## Passkeys are not a bypass

  `KilnCMSWeb.PasskeyController` completes a sign-in without a TOTP diversion,
  and that is the policy rather than an oversight: every Kiln passkey is
  registered *and* asserted with user verification required, so the ceremony
  already proves possession + PIN/biometric. It is also browser-only — there is
  no headless passkey route — so it is not a second door onto this surface.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.ApiError

  @doc """
  Exchange `email` + `password` for a bearer token.

  Body (`application/json`): `{"email": "...", "password": "..."}`.

  Success → `201 Created {"token": "<jwt>", "user": {"id", "email", "role"}}`,
  where `role` is the caller's **effective tier on the org this request resolved
  to** (per-org since #419, so it changes with the host dialed), not the global
  `User.role` (#627).
  Or, for an account with two-factor enabled,
  `200 OK {"two_factor_required": true, "pending_token": "...", "expires_in": 300}`
  — finish at `verify/2`.
  """
  def sign_in(conn, params) do
    email = params["email"]
    password = params["password"]

    with :ok <- require_params([{"email", email}, {"password", password}]),
         true <- is_binary(email) and is_binary(password),
         strategy = AshAuthentication.Info.strategy!(User, :password),
         {:ok, user} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{
             "email" => email,
             "password" => password
           }) do
      if Accounts.totp_enabled?(user) do
        two_factor_required(conn, user)
      else
        issue_token(conn, user)
      end
    else
      {:missing, detail} -> missing_params(conn, detail)
      # Includes `false` from the type check: a *supplied* email or password of
      # the wrong type is a bad credential, not a missing field.
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Complete a two-factor sign-in: exchange the `pending_token` from `sign_in/2`
  plus a TOTP or recovery code for the bearer token.

  Body (`application/json`): `{"pending_token": "...", "code": "123456"}`.
  Success → the same `201 Created` payload `sign_in/2` gives a 1FA account.
  """
  def verify(conn, params) do
    pending = params["pending_token"]
    code = params["code"]

    with :ok <- require_params([{"pending_token", pending}, {"code", code}]),
         {:ok, resolved} <- PendingSignIn.resolve(:encrypted, conn, pending),
         {:ok, user} <- SecondFactor.check(resolved.user, code),
         # Only now, and only on success: a wrong code or a spent budget leaves
         # the blob alive, because neither is a failed authentication and
         # neither should turn "that code isn't valid" into "start over".
         #
         # In the `with`, not beside it (#743). Claiming the blob is an INSERT
         # keyed on its `jti`, so a concurrent replay that also had a valid code
         # loses that race and lands here as `:taken` — and must be refused
         # rather than handed a token. Calling this and ignoring the answer
         # would leave exactly the replay the claim exists to stop.
         #
         # It is also what releases the first-factor token from the hold `mint/4`
         # took (#742): until this succeeds, the JWT in the blob authenticates
         # nothing, so a 201 issued without it would be a token the client cannot
         # use.
         :ok <- PendingSignIn.claim(resolved) do
      issue_token(conn, user)
    else
      {:missing, detail} ->
        missing_params(conn, detail)

      # Missing, malformed, expired, or naming an account that has since turned
      # two-factor off — plus `:taken`, a blob some other request has already
      # redeemed. All of them mean the same thing to a client: this exchange is
      # over, start again at `POST /api/auth/sign_in`.
      answer when answer in [:error, :taken] ->
        ApiError.send(
          conn,
          :unauthorized,
          "pending_expired",
          "Sign-in is no longer pending. Start again."
        )

      # Not the same answer (#743). Something could not be *recorded*, which is
      # not "this exchange is over" — so "start again" would be wrong advice as
      # well as a wasted trip through the password step and its throttle. A 503
      # says what is true: this did not complete, try it again shortly.
      #
      # Two things reach here and they leave the blob differently (#742):
      # a failed *claim* leaves it redeemable and the retry works; a failed
      # *release* happens after the claim committed, so the retry answers
      # `pending_expired` and the client restarts. Both are honest terminations,
      # and the second is the safe direction — a token that could not be
      # released stays parked rather than live and unheld.
      :unavailable ->
        ApiError.send(
          conn,
          :service_unavailable,
          "sign_in_unavailable",
          "Sign-in could not be completed right now. Try again in a moment."
        )

      # Alerting the owner is `SecondFactor.check/2`'s job, shared with the
      # browser prompt (#728) — a door that budgets the code but tells nobody
      # is #726's lesson repeated one layer up.
      {:deny, _user, retry_after_ms} ->
        # The pending token stays valid — the caller has not failed
        # authentication, and telling them to restart would be the wrong answer
        # to "you have tried too often". It will not usually outlive the wait
        # either: the budget window is fifteen minutes and this token lasts
        # five, so a refused client re-runs the password step and lands back
        # here — which buys them nothing, because the budget keys on the account
        # rather than on the token.
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(AccountThrottle.retry_after_seconds(retry_after_ms))
        )
        |> ApiError.send(
          :too_many_requests,
          "too_many_attempts",
          "Too many attempts. Try again later."
        )

      # `:invalid` from `SecondFactor.check/2` — and a catch-all, because that
      # module is shared with the browser prompt, whose own `else` is equally
      # narrow. Widening its return from `:invalid` to the more idiomatic
      # `{:error, reason}` is a one-line change that would otherwise turn an
      # unauthenticated route into a `WithClauseError` 500 instead of a 401.
      _ ->
        ApiError.send(conn, :unauthorized, "invalid_code", "That code isn't valid")
    end
  end

  # 200 rather than 201: nothing was created, and a client that keys off the
  # status alone must not mistake this for a token.
  defp two_factor_required(conn, user) do
    conn
    |> put_status(:ok)
    |> json(%{
      two_factor_required: true,
      pending_token: PendingSignIn.mint(:encrypted, conn, user),
      expires_in: PendingSignIn.max_age()
    })
  end

  defp issue_token(conn, user) do
    conn
    |> put_status(:created)
    |> json(%{
      token: user.__metadata__.token,
      # One shape for both steps, so the contract cannot drift between them.
      #
      # `role` is the caller's EFFECTIVE TIER on the org the request resolved to,
      # not `User.role` (the global one) — since #419 the authorization boundary
      # on org-scoped resources is the per-org tier, so a client pre-shaping its
      # UI (show/hide Approve) on the global role would offer actions the server
      # then refuses on any org where the membership tier is lower (#627). The
      # value therefore changes with the host the client dials; `SetTenant` has
      # already put that org on the conn. `:none` when the user has no tier there.
      user: %{
        id: user.id,
        email: to_string(user.email),
        role: Scoping.effective_tier(user, conn.assigns.current_org.id)
      }
    })
  end

  # Absent means absent. A field that was *supplied* with the wrong JSON type
  # falls through to the step that owns it, because "pending_token and code are
  # required" is actively misleading advice for a request that sent both — and
  # `code` is the field most likely to arrive unquoted, since most TOTP
  # libraries hand back an integer and six digits look like a number. (Leading
  # zeros make it intermittent, which is worse: `"012345"` stays a string.)
  defp require_params(named) do
    case Enum.filter(named, fn {_name, value} -> is_nil(value) end) do
      [] -> :ok
      [{name, _}] -> {:missing, "#{name} is required"}
      missing -> {:missing, Enum.map_join(missing, " and ", &elem(&1, 0)) <> " are required"}
    end
  end

  defp unauthorized(conn),
    do: ApiError.send(conn, :unauthorized, "invalid_credentials", "Invalid email or password")

  defp missing_params(conn, detail),
    do: ApiError.send(conn, :unprocessable_entity, "missing_parameters", detail)
end
