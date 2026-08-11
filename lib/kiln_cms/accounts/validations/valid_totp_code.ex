defmodule KilnCMS.Accounts.Validations.ValidTotpCode do
  @moduledoc """
  Validates that the `:code` argument is a currently-valid TOTP for a secret
  already on the record — `totp_secret` by default, or `:secret_field` to
  check a different one.

  `:confirm_totp` (#754) checks `totp_pending_secret` — the not-yet-proven
  secret staged by `:setup_totp` — rather than the live one, so that
  confirming a fresh enrolment never depends on (or touches) whatever secret
  is currently in force. `:disable_totp` and `:regenerate_totp_recovery_codes`
  keep the default: both act on the live factor and so must prove it.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.Totp

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.get(opts, :secret_field, :totp_secret)
    code = Ash.Changeset.get_argument(changeset, :code)
    secret = Map.fetch!(changeset.data, field)

    cond do
      is_nil(secret) ->
        {:error, field: :code, message: "two-factor authentication is not set up"}

      is_binary(code) and Totp.valid?(secret, code) ->
        :ok

      true ->
        {:error, field: :code, message: "that code isn't valid — check your authenticator app"}
    end
  end
end
