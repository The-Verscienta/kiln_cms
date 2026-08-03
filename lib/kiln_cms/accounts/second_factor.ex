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

  Charging that budget is the **caller's** job, and has to happen before this is
  called — see `KilnCMS.Accounts.AccountThrottle`'s moduledoc on why the gate
  must be the counter rather than a check followed by a later increment.

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
  alias KilnCMS.Accounts.Totp

  @doc """
  Verifies `code` against `user`'s TOTP secret, falling back to their recovery
  codes.

  Returns `{:ok, user}` — the *updated* record when a recovery code was burned,
  carrying the caller's `__metadata__` (and so the first-factor token) forward —
  or `:invalid`.
  """
  @spec verify(Accounts.User.t(), term()) :: {:ok, Accounts.User.t()} | :invalid
  def verify(user, code) when is_binary(code) do
    if is_binary(user.totp_secret) and Totp.valid?(user.totp_secret, code) do
      {:ok, user}
    else
      recovery_code(user, code)
    end
  end

  def verify(_user, _code), do: :invalid

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
