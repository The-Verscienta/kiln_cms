defmodule KilnCMS.Accounts.WebAuthnTest do
  @moduledoc """
  Passkey ceremony plumbing (#331) around the stubbed Wax seam: registration
  storage, assertion lookup, clone-detection counter, token minting, and the
  policy surface of the Passkey resource.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.PasskeyFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.WebAuthn

  describe "registration" do
    test "stores a verified credential with its metadata" do
      user = passkey_user()

      assert {:ok, passkey} = enroll(user, "cred-1", "MacBook")
      assert passkey.name == "MacBook"
      assert passkey.credential_id == b64("cred-1")
      assert passkey.sign_count == 0
      assert :erlang.binary_to_term(passkey.public_key) == %{stub: :cose_key}
      assert [%{name: "MacBook"}] = WebAuthn.list(user)
    end

    test "rejects a failed attestation and bad encodings" do
      user = passkey_user()

      assert {:error, :stub_rejected} = enroll(user, "bad")

      challenge = WebAuthn.registration_challenge()

      assert {:error, :invalid_encoding} =
               WebAuthn.register_passkey(user, challenge, %{
                 "attestation_object" => "not!!base64url",
                 "client_data_json" => "x"
               })
    end

    test "a credential id registers once (WebAuthn uniqueness)" do
      {:ok, _} = enroll(passkey_user(), "cred-dup")
      assert {:error, _} = enroll(passkey_user(), "cred-dup")
    end
  end

  describe "authentication" do
    test "a verified assertion returns the account with a session token" do
      user = passkey_user()
      {:ok, _} = enroll(user, "cred-auth")

      challenge = WebAuthn.authentication_challenge()

      assert {:ok, signed_in} = WebAuthn.authenticate(challenge, assertion("cred-auth"))
      assert signed_in.id == user.id
      assert is_binary(Ash.Resource.get_metadata(signed_in, :token))
    end

    test "unknown credentials and failed verification are rejected" do
      user = passkey_user()
      {:ok, _} = enroll(user, "cred-known")
      challenge = WebAuthn.authentication_challenge()

      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(challenge, assertion("cred-other"))

      assert {:error, :stub_rejected} =
               WebAuthn.authenticate(challenge, assertion("cred-known", signature: "bad"))
    end

    test "a signature-counter regression is rejected (clone detection)" do
      user = passkey_user()
      {:ok, _} = enroll(user, "cred-count")
      challenge = WebAuthn.authentication_challenge()

      # Counter advances: 5 then 6 — both fine; the row tracks the latest.
      assert {:ok, _} =
               WebAuthn.authenticate(challenge, assertion("cred-count", auth_data: "count:5"))

      assert {:ok, _} =
               WebAuthn.authenticate(challenge, assertion("cred-count", auth_data: "count:6"))

      # A replayed/cloned counter (≤ stored) fails closed.
      assert {:error, :sign_count_regression} =
               WebAuthn.authenticate(challenge, assertion("cred-count", auth_data: "count:6"))
    end
  end

  describe "challenge stash" do
    test "a parked challenge is consumed exactly once" do
      challenge = WebAuthn.authentication_challenge()
      nonce = WebAuthn.stash_challenge(challenge)

      assert %Wax.Challenge{} = WebAuthn.take_challenge(nonce)
      assert WebAuthn.take_challenge(nonce) == nil
      assert WebAuthn.take_challenge("bogus") == nil
      assert WebAuthn.take_challenge(nil) == nil
    end
  end

  describe "erasure (#212 interplay)" do
    test "anonymizing a user deletes their passkeys" do
      admin = passkey_user(:admin)
      user = passkey_user()
      {:ok, _} = enroll(user, "cred-gdpr")

      {:ok, _} = Accounts.anonymize_user(user, actor: admin)

      challenge = WebAuthn.authentication_challenge()

      # The credential is gone — the erased account cannot sign back in.
      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(challenge, assertion("cred-gdpr"))
    end
  end

  describe "passkey resource policies" do
    test "owners manage their own passkeys; others cannot" do
      owner = passkey_user()
      other = passkey_user()
      {:ok, passkey} = enroll(owner, "cred-own")

      assert [_] = Accounts.list_passkeys!(owner.id, actor: owner)
      # Another user reading the owner's list gets nothing (policy-filtered).
      assert [] = Accounts.list_passkeys!(owner.id, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.remove_passkey(passkey, actor: other)

      assert :ok = Accounts.remove_passkey(passkey, actor: owner)
    end

    test "sign_in_with_passkey never mints for an actor-carrying call" do
      target = passkey_user()

      # Ordinary callers are filter-forbidden by the policy…
      assert {:ok, nil} =
               Accounts.complete_passkey_sign_in(target.id,
                 actor: passkey_user(:editor),
                 not_found_error?: false
               )

      # …and the admin bypass is neutralized by the preparation's actor guard.
      assert {:ok, nil} =
               Accounts.complete_passkey_sign_in(target.id,
                 actor: passkey_user(:admin),
                 not_found_error?: false
               )
    end
  end
end
