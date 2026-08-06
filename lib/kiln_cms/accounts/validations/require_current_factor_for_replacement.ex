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
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.Totp

  @impl true
  def validate(changeset, _opts, _context) do
    data = changeset.data
    replacing? = not is_nil(data.totp_confirmed_at) and is_binary(data.totp_secret)

    cond do
      not replacing? ->
        :ok

      Ash.Changeset.get_argument(changeset, :recovery_login?) == true ->
        :ok

      valid_current?(data.totp_secret, Ash.Changeset.get_argument(changeset, :current_code)) ->
        :ok

      true ->
        {:error,
         field: :current_code,
         message:
           "enter a code from your current authenticator to replace two-factor authentication"}
    end
  end

  defp valid_current?(secret, code) when is_binary(code), do: Totp.valid?(secret, code)
  defp valid_current?(_secret, _code), do: false
end
