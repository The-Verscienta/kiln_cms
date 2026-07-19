defmodule KilnCMS.PasskeyFixtures do
  @moduledoc """
  Shared passkey-test scaffolding (#331): seeded users, enrolment through the
  real `KilnCMS.Accounts.WebAuthn` plumbing (over `KilnCMS.StubWebAuthnVerifier`),
  and assertion payload builders. One home for the stub's wire contract so the
  ceremony tests and the controller tests can't drift apart.
  """

  alias KilnCMS.Accounts.WebAuthn

  def passkey_user(role \\ :editor) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "passkey-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  def b64(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "Register `credential_bytes` for `user` through the real ceremony."
  def enroll(user, credential_bytes, name \\ "Test key") do
    challenge = WebAuthn.registration_challenge()

    WebAuthn.register_passkey(user, challenge, %{
      "attestation_object" => b64(credential_bytes),
      "client_data_json" => b64(~s({"type":"webauthn.create"})),
      "name" => name
    })
  end

  @doc "A sign-in assertion payload for `credential_bytes` (see the stub)."
  def assertion(credential_bytes, opts \\ []) do
    %{
      "credential_id" => b64(credential_bytes),
      "authenticator_data" => b64(Keyword.get(opts, :auth_data, "auth")),
      "signature" => b64(Keyword.get(opts, :signature, "sig")),
      "client_data_json" => b64(~s({"type":"webauthn.get"}))
    }
  end
end
