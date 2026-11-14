defmodule KilnCMS.Accounts.Validations.RequireCurrentFactorForReplacement do
  @moduledoc """
  On `:confirm_totp`, when the account ALREADY holds a confirmed live TOTP
  secret, promoting a freshly-enrolled pending secret over it must prove control
  of the OUTGOING factor — a current code from the live `totp_secret` — UNLESS
  the session was established via a recovery code (`recovery_login?`), which has
  already proved account access some other way (#786).

  #754 stopped `:setup_totp` from turning 2FA off by itself, but left a narrower
  gap: `:setup_totp` (which proves nothing) followed by `:confirm_totp` with the
  new secret's own code — trivial, it's the caller's own freshly-generated
  secret — still **replaced which secret backs the account's live 2FA**, silently.
  `totp_confirmed_at` never dropped, so nothing about the visible state looked
  wrong, but the owner's authenticator stopped working and whoever ran the pair
  held the only valid second factor.

  A **first** enrolment (no confirmed secret yet) is unaffected — there is no
  outgoing factor to prove — which is also what keeps enrolment self-service.
  The recovery-code carve-out is what keeps **re-enrolment** self-service for
  someone who lost their authenticator: they signed in with a recovery code and
  have no live code to offer, and the recovery-code sign-in already stood in for
  the factor. `recovery_login?` is set by the caller from server-side session
  provenance, never from client input, and there is no API route to this action.

  ## Decided from the stored row, under the action's lock

  Whether a live factor exists, and which secret the current code is checked
  against, are read from the database, never from `changeset.data`. The struct
  a settings page passes in is its `current_user` assign: a tab mounted before
  the account enrolled elsewhere still holds `totp_confirmed_at: nil`, and
  reading that would treat a replacement as a first enrollment and skip the
  outgoing-code check altogether (GHSA-5g35-j8qr-j475).

  Declared with `before_action?: true` below `GuardAccountTakeover`, which
  takes the row `FOR NO KEY UPDATE` in its own `before_action`, so the re-read
  sees what any concurrent confirmation committed and nothing can enroll in
  between. A missing row falls back to the loaded struct; the update itself
  then fails.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.TotpSecrets

  @impl true
  def validate(changeset, _opts, _context) do
    stored = stored(changeset.data)

    # Keyed on `totp_confirmed_at` ALONE — the same predicate that enforces 2FA at
    # sign-in (`Accounts.totp_enabled?/1`), and which `SecondFactor` still honors
    # via recovery codes when `totp_secret` is nil. Gating on the secret too would
    # leave a `confirmed_at`-set-but-`secret`-nil account (a partial write, a
    # restore, a future rotate) enforcing 2FA yet skippable here. With a nil
    # secret `valid_current?` can't pass, so only a recovery-code session may
    # re-enrol — exactly right for an account reachable only by recovery code.
    replacing? = not is_nil(stored.totp_confirmed_at)

    cond do
      not replacing? ->
        :ok

      Ash.Changeset.get_argument(changeset, :recovery_login?) == true ->
        :ok

      valid_current?(
        TotpSecrets.live(stored),
        Ash.Changeset.get_argument(changeset, :current_code)
      ) ->
        :ok

      true ->
        {:error,
         field: :current_code,
         message:
           "enter a code from your current authenticator to replace two-factor authentication"}
    end
  end

  defp stored(data) do
    # authorize?: false — a re-read of the very row this authorized action is
    # updating, for the two private columns that decide this check. Nothing
    # read here leaves the validation.
    case Accounts.get_user(data.id, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{} = row} -> row
      _missing -> data
    end
  end

  defp valid_current?(secret, code) when is_binary(secret) and is_binary(code),
    do: Totp.valid?(secret, code)

  defp valid_current?(_secret, _code), do: false
end
