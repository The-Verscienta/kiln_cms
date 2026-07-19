defmodule KilnCMS.Accounts.WebAuthnTest do
  @moduledoc """
  Passkey ceremony plumbing (#331) around the stubbed Wax seam: registration
  storage, assertion lookup, clone-detection counter, token minting, and the
  policy surface of the Passkey resource.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.WebAuthn

  defp user(role \\ :editor) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "passkey-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp enroll(user, credential_bytes, name \\ "Test key") do
    challenge = WebAuthn.registration_challenge()

    WebAuthn.register_passkey(user, challenge, %{
      "attestation_object" => b64(credential_bytes),
      "client_data_json" => b64(~s({"type":"webauthn.create"})),
      "name" => name
    })
  end

  defp assertion(credential_bytes, opts \\ []) do
    %{
      "credential_id" => b64(credential_bytes),
      "authenticator_data" => b64(Keyword.get(opts, :auth_data, "auth")),
      "signature" => b64(Keyword.get(opts, :signature, "sig")),
      "client_data_json" => b64(~s({"type":"webauthn.get"}))
    }
  end

  describe "registration" do
    test "stores a verified credential with its metadata" do
      user = user()

      assert {:ok, passkey} = enroll(user, "cred-1", "MacBook")
      assert passkey.name == "MacBook"
      assert passkey.credential_id == b64("cred-1")
      assert passkey.sign_count == 0
      assert :erlang.binary_to_term(passkey.public_key) == %{stub: :cose_key}
      assert [%{name: "MacBook"}] = WebAuthn.list(user)
    end

    test "rejects a failed attestation and bad encodings" do
      user = user()

      assert {:error, :stub_rejected} = enroll(user, "bad")

      challenge = WebAuthn.registration_challenge()

      assert {:error, :invalid_encoding} =
               WebAuthn.register_passkey(user, challenge, %{
                 "attestation_object" => "not!!base64url",
                 "client_data_json" => "x"
               })
    end

    test "a credential id registers once (WebAuthn uniqueness)" do
      {:ok, _} = enroll(user(), "cred-dup")
      assert {:error, _} = enroll(user(), "cred-dup")
    end
  end

  describe "authentication" do
    test "a verified assertion returns the account with a session token" do
      user = user()
      {:ok, _} = enroll(user, "cred-auth")

      challenge = WebAuthn.authentication_challenge()

      assert {:ok, signed_in} = WebAuthn.authenticate(challenge, assertion("cred-auth"))
      assert signed_in.id == user.id
      assert is_binary(Ash.Resource.get_metadata(signed_in, :token))
    end

    test "unknown credentials and failed verification are rejected" do
      user = user()
      {:ok, _} = enroll(user, "cred-known")
      challenge = WebAuthn.authentication_challenge()

      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(challenge, assertion("cred-other"))

      assert {:error, :stub_rejected} =
               WebAuthn.authenticate(challenge, assertion("cred-known", signature: "bad"))
    end

    test "a signature-counter regression is rejected (clone detection)" do
      user = user()
      {:ok, _} = enroll(user, "cred-count")
      challenge = WebAuthn.authentication_challenge()

      # Counter advances: 5 then 6 — both fine; the row tracks the latest.
      assert {:ok, _} =
               WebAuthn.authenticate(
                 challenge,
                 assertion("cred-count", auth_data: "count:5")
               )

      assert {:ok, _} =
               WebAuthn.authenticate(
                 challenge,
                 assertion("cred-count", auth_data: "count:6")
               )

      # A replayed/cloned counter (≤ stored) fails closed.
      assert {:error, :sign_count_regression} =
               WebAuthn.authenticate(
                 challenge,
                 assertion("cred-count", auth_data: "count:6")
               )
    end
  end

  describe "passkey resource policies" do
    test "owners manage their own passkeys; others cannot" do
      owner = user()
      other = user()
      {:ok, passkey} = enroll(owner, "cred-own")

      assert [_] = Accounts.list_passkeys!(owner.id, actor: owner)
      # Another user reading the owner's list gets nothing (policy-filtered).
      assert [] = Accounts.list_passkeys!(owner.id, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.remove_passkey(passkey, actor: other)

      assert :ok = Accounts.remove_passkey(passkey, actor: owner)
    end

    test "sign_in_with_passkey yields nothing for authorized callers" do
      target = user()
      caller = user(:editor)

      # Read policies filter: an authorized caller gets no record — and
      # therefore no token minted for another account (the after_action only
      # runs over returned records).
      assert {:ok, nil} =
               KilnCMS.Accounts.User
               |> Ash.Query.for_read(:sign_in_with_passkey, %{user_id: target.id})
               |> Ash.read_one(actor: caller)
    end
  end
end
