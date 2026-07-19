defmodule KilnCMS.StubWebAuthnVerifier do
  @moduledoc """
  Test double for the Wax verification seam (`KilnCMS.Accounts.WebAuthn`).

  Implements `register/3` and `authenticate/6` with Wax's signatures but
  decides success from the payload itself instead of cryptography:

    * `register/3` succeeds unless the attestation object is `"bad"`,
      minting a credential whose id is the attestation bytes.
    * `authenticate/6` succeeds when the credential id appears in the
      credentials list (mirroring Wax's lookup) and the signature is not
      `"bad"`; the reported sign count is read from the authenticator data
      (`"count:N"`), defaulting to 0.

  Everything around the seam — base64url plumbing, storage, uniqueness,
  counter regression, token minting, session establishment — runs for real.
  """

  def register("bad", _client_data_json, _challenge), do: {:error, :stub_rejected}

  def register(attestation, _client_data_json, _challenge) do
    auth_data = %{
      sign_count: 0,
      flag_user_verified: true,
      attested_credential_data: %{
        credential_id: attestation,
        credential_public_key: %{stub: :cose_key}
      }
    }

    {:ok, {auth_data, :none}}
  end

  def authenticate(_id, _auth_data, "bad", _client_data, _challenge, _credentials),
    do: {:error, :stub_rejected}

  def authenticate(credential_id, auth_data_bin, _sig, _client_data, _challenge, credentials) do
    case List.keyfind(credentials, credential_id, 0) do
      {_, _cose_key} -> {:ok, %{sign_count: reported_count(auth_data_bin)}}
      _ -> {:error, :stub_unknown_credential}
    end
  end

  defp reported_count("count:" <> n), do: String.to_integer(n)
  defp reported_count(_auth_data), do: 0
end
