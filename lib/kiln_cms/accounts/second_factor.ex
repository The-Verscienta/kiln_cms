defmodule KilnCMS.Accounts.SecondFactor do
  @moduledoc """
  Checks a submitted second factor — a TOTP code, or a one-time recovery code —
  against an account (#331, #726).

  One implementation, because there are two surfaces that reach it: the browser
  prompt at `/sign-in/verify` (`KilnCMSWeb.TwoFactorController`) and the headless
  exchange at `POST /api/auth/sign_in/verify` (`KilnCMSWeb.ApiAuthController`).
  A second copy is a second place for the two to disagree about what counts as
  the same code.

  (The *normalization* half of that agreement lives one level further down, in
  `KilnCMS.Accounts.Totp.valid?/3`, because there is a third caller — the
  enrolment and disable forms go through
  `KilnCMS.Accounts.Validations.ValidTotpCode`, which has no recovery-code
  fallback and so cannot come through here. Putting the whitespace strip in this
  module left `123 456` working at sign-in and failing at disable.)

  ## TOTP first, then recovery codes

  Both are checked against a single submission because the user is given one
  field. They also share one budget: an attacker who cannot guess the TOTP will
  pivot to the recovery codes, and two budgets would simply be one budget twice
  as large.

  `check/2` is the whole public surface, and it owns charge → verify → forgive
  so that ordering is a property of this module rather than of two call sites —
  see `KilnCMS.Accounts.AccountThrottle`'s moduledoc on why the gate must be
  the counter rather than a check followed by a later increment. The code check
  alone is private: there is no caller for an unbudgeted one, and offering it
  would be offering the check-then-count shape back.

  ## A missing secret must not take the recovery codes with it

  An account can be `totp_enabled?` (which reads `totp_confirmed_at`) while its
  `totp_secret` is nil — not through any shipped action, but a partial write, a
  restore, or a future "rotate the secret" action all produce it. Recovery codes
  are exactly the escape hatch for "the authenticator is unavailable", and they
  need no secret, so the nil case falls *through* to them rather than short-
  circuiting to `:invalid`. Short-circuiting would have made such an account
  unreachable through both surfaces, burning one of five attempts per try, with
  no self-service remedy — a floor that also removes the ladder.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.SignInAlert
  alias KilnCMS.Accounts.Totp

  @doc """
  The whole second-factor step for a sign-in gate: charge, verify, forgive
  (#714, #726, #728, #745).

      :ok             -> {:ok, user}
      wrong code      -> :invalid
      budget spent    -> {:deny, user, retry_after_ms}

  One function because the **order** is the thing worth protecting, and it was
  previously enforced by prose in two places. `AccountThrottle`'s moduledoc
  names check-then-count as the bug class it exists to prevent: the charge has
  to land before the code is looked at, or a burst of simultaneous submissions
  all read "under budget" and all get a full verification. Getting it backwards
  fails *silently* — still 401ing wrong codes, just with an unbounded budget.
  As a property of this module it cannot be got backwards at a call site.

  The refusal carries the user back out because a `with`'s `else` cannot see
  its clause bindings, and both gates need it for the `retry-after` header.

  The owner alert (#728) belongs here rather than to the budget itself:
  `KilnCMS.Accounts.Changes.ThrottleSecondFactor` charges the same bucket from
  `/editor/settings` (#727), and that refusal is different news — the person
  there holds a session, not a first factor. See #757.
  """
  @spec check(Accounts.User.t(), term()) ::
          {:ok, Accounts.User.t()} | :invalid | {:deny, Accounts.User.t(), non_neg_integer()}
  def check(user, code) do
    case AccountThrottle.consume_second_factor(user.id) do
      :allow ->
        forgive_on_success(verify(user, code))

      {:deny, retry_after_ms} ->
        SignInAlert.second_factor_locked(user)
        {:deny, user, retry_after_ms}
    end
  end

  # Someone whose authenticator was a minute out of sync, or who fumbled a
  # recovery code, has now proved they hold the factor; carrying those failures
  # into their next sign-in would lock out the person the budget protects.
  # Keyed on the verified record rather than the one passed in. They are the
  # same id — `:consume_totp_recovery_code` only rewrites the hash list — but
  # forgiving what was actually proved is the reading that stays correct if that
  # ever changes.
  #
  # The **sign-in** counter is forgiven here too (#742) — and for an account
  # that owes a second factor, this is the only place it is
  # (`ForgiveSignInThrottle` and the passkey path forgive it as well, but
  # neither is reachable by finishing a code prompt).
  # `ThrottleSignIn` charges it at the password step and no longer clears it for
  # a 2FA account, because a first factor that stops at the code prompt is not a
  # completed sign-in — it is exactly what an attacker holding a stuffed
  # password produces, over and over, resetting the counter each time. This is
  # the moment the sign-in is genuinely complete, so this is where it is
  # cleared. Keyed on the address rather than the id, matching what
  # `ThrottleSignIn` charged; `AccountThrottle.digest/1` normalizes both, so a
  # differently-cased submission still resolves to the same bucket.
  defp forgive_on_success({:ok, verified}) do
    AccountThrottle.forgive_second_factor(verified.id)
    AccountThrottle.forgive(to_string(verified.email))
    {:ok, verified}
  end

  defp forgive_on_success(:invalid), do: :invalid

  # Verifies `code` against `user`'s TOTP secret, falling back to their recovery
  # codes. `{:ok, user}` — the *updated* record when a recovery code was burned,
  # carrying the caller's `__metadata__` (and so the first-factor token)
  # forward — or `:invalid`.
  @spec verify(Accounts.User.t(), term()) :: {:ok, Accounts.User.t()} | :invalid
  defp verify(user, code) when is_binary(code) do
    if is_binary(user.totp_secret) and Totp.valid?(user.totp_secret, code) do
      {:ok, user}
    else
      recovery_code(user, code)
    end
  end

  defp verify(_user, _code), do: :invalid

  # An empty set is checked here rather than left to the action: with no hashes
  # stored there is nothing a code could match, and skipping the changeset keeps
  # the wrong-code path — the only path a grinder ever takes — off the Ash
  # pipeline entirely.
  defp recovery_code(%{totp_recovery_hashes: hashes}, _code) when hashes in [nil, []],
    do: :invalid

  defp recovery_code(user, code) do
    case Accounts.consume_totp_recovery_code(user, %{code: code}, authorize?: false) do
      # The consume action returns a fresh record; the caller's metadata (the
      # already-minted first-factor token) is reattached so the sign-in can be
      # completed from it.
      {:ok, updated} -> {:ok, %{updated | __metadata__: user.__metadata__}}
      {:error, _reason} -> :invalid
    end
  end
end
