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

  describe "step-up (#2247)" do
    test "the challenge allows exactly the account's own credentials" do
      user = passkey_user()
      other = passkey_user()
      {:ok, _} = enroll(user, "su-own-1")
      {:ok, _} = enroll(user, "su-own-2")
      {:ok, _} = enroll(other, "su-other")

      challenge = WebAuthn.step_up_challenge(user)

      assert challenge.allow_credentials |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["su-own-1", "su-own-2"]

      assert challenge.user_verification == "required"

      assert %{allowCredentials: listed, userVerification: "required"} =
               WebAuthn.step_up_options(challenge)

      assert listed |> Enum.map(& &1.id) |> Enum.sort() == [b64("su-own-1"), b64("su-own-2")]
      assert Enum.all?(listed, &(&1.type == "public-key"))
    end

    test "a verified assertion returns the same account and mints nothing" do
      user = passkey_user()
      {:ok, _} = enroll(user, "su-ok")
      user = %{user | __metadata__: Map.put(user.__metadata__, :token, "first.factor.jwt")}

      assert {:ok, verified} =
               WebAuthn.verify_step_up(
                 WebAuthn.step_up_challenge(user),
                 assertion("su-ok"),
                 user
               )

      assert verified.id == user.id
      # The first factor's token rides through; no new one is minted.
      assert Ash.Resource.get_metadata(verified, :token) == "first.factor.jwt"
    end

    test "another account's passkey is refused" do
      user = passkey_user()
      other = passkey_user()
      {:ok, _} = enroll(user, "su-mine")
      {:ok, _} = enroll(other, "su-theirs")

      assert {:error, _} =
               WebAuthn.verify_step_up(
                 WebAuthn.step_up_challenge(user),
                 assertion("su-theirs"),
                 user
               )
    end

    test "a challenge minted for one account does not complete another's sign-in" do
      # The other account's challenge lists the other account's credential, so
      # Wax's allow-list would pass it: the owner check is what refuses.
      user = passkey_user()
      other = passkey_user()
      {:ok, _} = enroll(user, "su-x")
      {:ok, _} = enroll(other, "su-y")

      assert {:error, :not_owner} =
               WebAuthn.verify_step_up(
                 WebAuthn.step_up_challenge(other),
                 assertion("su-y"),
                 user
               )
    end

    test "the account's own credential outside the challenge's allow-list is refused" do
      # The owner check passes here, so this is the allow-list alone: a passkey
      # added after the challenge was minted is not one it allows.
      user = passkey_user()
      {:ok, _} = enroll(user, "su-before")
      challenge = WebAuthn.step_up_challenge(user)
      {:ok, _} = enroll(user, "su-after")

      assert {:error, _} = WebAuthn.verify_step_up(challenge, assertion("su-after"), user)
      assert {:ok, _} = WebAuthn.verify_step_up(challenge, assertion("su-before"), user)
    end

    test "a challenge with no allow-list is not a step-up" do
      user = passkey_user()
      {:ok, _} = enroll(user, "su-open")

      assert {:error, :no_allow_list} =
               WebAuthn.verify_step_up(
                 WebAuthn.authentication_challenge(),
                 assertion("su-open"),
                 user
               )
    end

    test "an assertion without the user-verified flag is refused" do
      user = passkey_user()
      {:ok, _} = enroll(user, "su-nouv")

      assert {:error, :user_not_verified} =
               WebAuthn.verify_step_up(
                 WebAuthn.step_up_challenge(user),
                 assertion("su-nouv", auth_data: "nouv"),
                 user
               )
    end

    test "a signature-counter regression is refused" do
      user = passkey_user()
      {:ok, _} = enroll(user, "su-count")
      challenge = WebAuthn.step_up_challenge(user)

      assert {:ok, _} =
               WebAuthn.verify_step_up(
                 challenge,
                 assertion("su-count", auth_data: "count:3"),
                 user
               )

      assert {:error, :sign_count_regression} =
               WebAuthn.verify_step_up(
                 challenge,
                 assertion("su-count", auth_data: "count:3"),
                 user
               )
    end

    test "bad encodings and unknown credentials are refused" do
      user = passkey_user()
      {:ok, _} = enroll(user, "su-enc")
      challenge = WebAuthn.step_up_challenge(user)

      assert {:error, :invalid_encoding} =
               WebAuthn.verify_step_up(challenge, %{"credential_id" => "!!"}, user)

      assert {:error, :unknown_credential} =
               WebAuthn.verify_step_up(challenge, assertion("su-ghost"), user)
    end
  end

  describe "the anonymous sign-in checks the user-verified flag too" do
    test "an assertion without it is refused" do
      user = passkey_user()
      {:ok, _} = enroll(user, "auth-nouv")

      assert {:error, :user_not_verified} =
               WebAuthn.authenticate(
                 WebAuthn.authentication_challenge(),
                 assertion("auth-nouv", auth_data: "nouv")
               )
    end
  end

  describe "ceremony hosts (#2247)" do
    test "the canonical host runs ceremonies; a tenant site host does not" do
      assert WebAuthn.ceremony_host?("localhost")
      assert WebAuthn.ceremony_host?("LOCALHOST")
      refute WebAuthn.ceremony_host?("www.example.com")
      refute WebAuthn.ceremony_host?("acme.localhost.evil.test")
      refute WebAuthn.ceremony_host?(nil)
    end
  end

  describe "step-up challenge stash (#2247)" do
    test "is single use and bound to the account it was parked for" do
      user = passkey_user()
      {:ok, _} = enroll(user, "stash-su")
      challenge = WebAuthn.step_up_challenge(user)

      nonce = WebAuthn.stash_step_up_challenge(challenge, user.id)
      assert %Wax.Challenge{} = WebAuthn.take_step_up_challenge(nonce, user.id)
      assert WebAuthn.take_step_up_challenge(nonce, user.id) == nil

      # Another account's pending sign-in gets nothing, and the try spends it.
      nonce = WebAuthn.stash_step_up_challenge(challenge, user.id)
      assert WebAuthn.take_step_up_challenge(nonce, Ecto.UUID.generate()) == nil
      assert WebAuthn.take_step_up_challenge(nonce, user.id) == nil

      assert WebAuthn.take_step_up_challenge(nil, user.id) == nil
    end

    test "neither ceremony's nonce is taken by the other's take" do
      user = passkey_user()
      {:ok, _} = enroll(user, "stash-cross")

      step_up = WebAuthn.stash_step_up_challenge(WebAuthn.step_up_challenge(user), user.id)
      assert WebAuthn.take_challenge(step_up) == nil

      anonymous = WebAuthn.stash_challenge(WebAuthn.authentication_challenge())
      assert WebAuthn.take_step_up_challenge(anonymous, user.id) == nil
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
