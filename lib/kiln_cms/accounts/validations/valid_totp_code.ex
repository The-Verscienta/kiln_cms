defmodule KilnCMS.Accounts.Validations.ValidTotpCode do
  @moduledoc """
  Validates that the `:code` argument is a currently-valid TOTP for the user's
  stored secret. Used by the confirm/disable 2FA actions so neither can proceed
  without proof of the authenticator device.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.Totp

  @impl true
  def validate(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)
    secret = changeset.data.totp_secret

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
