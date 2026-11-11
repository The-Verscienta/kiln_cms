defmodule KilnCMS.Accounts.PreHijackTakeoverTest do
  @moduledoc """
  The owner of an address taking over an account someone else registered for
  it in advance (#2594), by routes other than an invitation (#2453, covered by
  `InvitationTakeoverCredentialsTest`).

  A password reset finished on an **unconfirmed** account removes every
  credential the first registrant could have set up: two-step verification and
  its recovery codes, passkeys, identity-provider links, push devices and API
  keys. The same reset on a **confirmed** account keeps all of them, or a reset
  would be a way past two-step verification.

  Erasure (`User.:anonymize`) clears the TOTP columns too, read from the row
  rather than the caller's struct.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.PasskeyFixtures, only: [enroll: 2, assertion: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.UserIdentity
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Repo
  alias KilnCMS.Security

  @moduletag :capture_log

  @new_password "owner-new-password-123"
  @old_password "squatter-password-456"
  @recovery_code "ABCD-EFGH"

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "prehijack-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@old_password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp squatter!, do: user(:viewer, %{confirmed_at: nil})

  defp enroll_totp!(user) do
    Ash.Seed.update!(user, %{
      totp_secret: Totp.generate_secret(),
      totp_confirmed_at: DateTime.utc_now(),
      totp_pending_secret: Totp.generate_secret(),
      totp_recovery_hashes: [RecoveryCodes.hash(@recovery_code)]
    })
  end

  defp identity!(user),
    do:
      Ash.Seed.seed!(UserIdentity, %{
        user_id: user.id,
        strategy: "oidc",
        uid: "stranger-#{uniq()}"
      })

  defp device!(user),
    do:
      Ash.Seed.seed!(PushSubscription, %{
        user_id: user.id,
        endpoint: "https://push.example.com/#{uniq()}",
        p256dh: "p256dh",
        auth: "auth"
      })

  defp key!(user, admin) do
    days = &DateTime.add(DateTime.utc_now(), &1, :day)

    Accounts.mint_api_key!(
      user.id,
      "stranger's key",
      days.(7),
      %{access: :draft_write, rotatable_until: days.(180)},
      actor: admin
    )
  end

  defp plaintext(key), do: Ash.Resource.get_metadata(key, :plaintext_api_key)

  defp strategy, do: AshAuthentication.Info.strategy!(User, :password)

  defp sign_in(email, password) do
    AshAuthentication.Strategy.action(
      strategy(),
      :sign_in,
      %{"email" => to_string(email), "password" => password},
      []
    )
  end

  # The strategy's own entry point, what `/auth/user/password/reset` calls,
  # with the token the reset mail would carry.
  defp reset_password(user) do
    {:ok, reset_token} = AshAuthentication.Strategy.Password.reset_token_for(strategy(), user)

    AshAuthentication.Strategy.action(
      strategy(),
      :reset,
      %{
        "reset_token" => reset_token,
        "password" => @new_password,
        "password_confirmation" => @new_password
      },
      []
    )
  end

  defp confirmation, do: AshAuthentication.Info.strategy!(User, :confirm_new_user)

  defp confirmation_token(user) do
    {:ok, token} =
      AshAuthentication.AddOn.Confirmation.confirmation_token(
        confirmation(),
        Ash.Changeset.new(user),
        user
      )

    token
  end

  defp confirm(token, params) do
    AshAuthentication.Strategy.action(
      confirmation(),
      :confirm,
      Map.put(params, "confirm", token),
      []
    )
  end

  defp magic_link, do: AshAuthentication.Info.strategy!(User, :magic_link)

  defp magic_sign_in(user) do
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(magic_link(), user)
    AshAuthentication.Strategy.action(magic_link(), :sign_in, %{"token" => token}, [])
  end

  # A session the first registrant signed in with: a stored token for the
  # account, as a password sign-in mints.
  defp session!(user) do
    {:ok, signed_in} = sign_in(user.email, @old_password)
    signed_in.__metadata__.token
  end

  # The token's stored row still says "user": not revoked.
  defp token_live?(token) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    Repo.one(from(t in "tokens", where: t.jti == ^jti, select: t.purpose)) == "user"
  end

  defp identities(user_id),
    do:
      Repo.aggregate(
        from(i in "user_identities", where: i.user_id == type(^user_id, Ecto.UUID)),
        :count
      )

  defp events(admin, user_id, type) do
    Security.list_events!(actor: admin, tenant: Accounts.default_org_id(), page: [limit: 200])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type and &1.target_id == user_id))
  end

  defp passkey_bytes(passkey), do: Base.url_decode64!(passkey.credential_id, padding: false)

  setup do
    %{admin: user(:admin)}
  end

  describe "a password reset finished on an unconfirmed account" do
    test "confirms it and removes every credential the first registrant set up",
         %{admin: admin} do
      squatter = enroll_totp!(squatter!())
      {:ok, passkey} = enroll(squatter, "stranger-cred-#{uniq()}")
      identity!(squatter)
      device!(squatter)
      key = key!(squatter, admin)
      stranger_session = session!(squatter)
      assert token_live?(stranger_session)

      assert {:ok, reset} = reset_password(squatter)
      assert reset.__metadata__[:forgotten_credentials] == true

      row = Repo.reload!(reset)
      assert %DateTime{} = row.confirmed_at
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_pending_secret == nil
      assert row.totp_recovery_hashes == []

      # The sign-in the reset completes is not held at a code prompt only the
      # stranger could answer.
      refute Accounts.totp_enabled?(reset)

      # The stranger's password, session, recovery code, passkey and key are
      # all dead; the owner's new password signs in with no second factor.
      assert {:error, _} = sign_in(squatter.email, @old_password)
      refute token_live?(stranger_session)
      assert SecondFactor.check(row, @recovery_code) == :invalid

      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(
                 WebAuthn.authentication_challenge(),
                 assertion(passkey_bytes(passkey))
               )

      assert Accounts.list_passkeys!(squatter.id, actor: admin) == []
      assert identities(squatter.id) == 0
      assert Accounts.list_push_subscriptions!(squatter.id, actor: admin) == []
      assert :error = Accounts.actor_from_api_key(plaintext(key))

      assert {:ok, signed_in} = sign_in(squatter.email, @new_password)
      refute Accounts.totp_enabled?(signed_in)

      # On the record, with no actor and the reset as the route.
      assert [factor] = events(admin, squatter.id, :second_factor_removed)
      assert factor.actor_id == nil
      assert factor.metadata == %{"kind" => "totp", "via" => "password_reset"}

      assert [removed] = events(admin, squatter.id, :passkey_removed)
      assert removed.actor_id == nil
      assert removed.metadata == %{"name" => passkey.name, "via" => "password_reset"}
    end

    test "reads the factors from the locked row, not the struct the token named",
         %{admin: admin} do
      # The reset token is minted from a read made before the stranger enrolled.
      stale = squatter!()
      enroll_totp!(stale)

      assert stale.totp_confirmed_at == nil
      assert {:ok, reset} = reset_password(stale)

      row = Repo.reload!(reset)
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_recovery_hashes == []
      assert [_] = events(admin, stale.id, :second_factor_removed)
    end
  end

  describe "a password reset on a confirmed account" do
    test "keeps its second factor, passkeys, devices and keys", %{admin: admin} do
      owner = enroll_totp!(user(:viewer))
      {:ok, passkey} = enroll(owner, "owner-cred-#{uniq()}")
      identity!(owner)
      device!(owner)
      key = key!(owner, admin)

      assert {:ok, reset} = reset_password(owner)
      assert reset.__metadata__[:forgotten_credentials] == false

      row = Repo.reload!(reset)
      assert row.totp_secret == owner.totp_secret
      assert %DateTime{} = row.totp_confirmed_at
      assert row.totp_recovery_hashes == owner.totp_recovery_hashes

      # A reset is no way past two-step verification.
      assert Accounts.totp_enabled?(reset)

      assert [%{id: id}] = Accounts.list_passkeys!(owner.id, actor: admin)
      assert id == passkey.id
      assert identities(owner.id) == 1
      assert [_] = Accounts.list_push_subscriptions!(owner.id, actor: admin)
      assert {:ok, _} = Accounts.actor_from_api_key(plaintext(key))

      assert events(admin, owner.id, :second_factor_removed) == []
      assert events(admin, owner.id, :passkey_removed) == []
    end
  end

  describe "the confirmation link" do
    test "asks for the sign-up password: with it, confirms and keeps every factor",
         %{admin: admin} do
      registrant = enroll_totp!(squatter!())
      {:ok, _passkey} = enroll(registrant, "own-cred-#{uniq()}")
      token = confirmation_token(registrant)

      assert {:ok, confirmed} = confirm(token, %{"password" => @old_password})
      assert %DateTime{} = confirmed.confirmed_at
      assert is_binary(confirmed.__metadata__.token)

      row = Repo.reload!(confirmed)
      assert row.totp_secret == registrant.totp_secret
      assert [_] = Accounts.list_passkeys!(registrant.id, actor: admin)
      assert {:ok, _} = sign_in(registrant.email, @old_password)
    end

    test "is refused without the password, or with a wrong one, and is not used up" do
      registrant = squatter!()
      token = confirmation_token(registrant)

      assert {:error, _} = confirm(token, %{})
      assert {:error, _} = confirm(token, %{"password" => "not-the-password-1"})
      assert Repo.reload!(registrant).confirmed_at == nil

      # Whoever holds the right password can still use the same link.
      assert {:ok, %User{confirmed_at: %DateTime{}}} =
               confirm(token, %{"password" => @old_password})
    end

    test "cannot change the address through the form" do
      registrant = squatter!()
      token = confirmation_token(registrant)

      assert {:error, _} =
               confirm(token, %{"password" => @old_password, "email" => "other@example.com"})

      row = Repo.reload!(registrant)
      assert row.confirmed_at == nil
      assert to_string(row.email) == to_string(registrant.email)
    end
  end

  describe "a magic-link sign-in to an unconfirmed account" do
    test "confirms it and removes every credential the first registrant set up",
         %{admin: admin} do
      squatter = enroll_totp!(squatter!())
      {:ok, passkey} = enroll(squatter, "stranger-cred-#{uniq()}")
      identity!(squatter)
      device!(squatter)
      key = key!(squatter, admin)
      stranger_session = session!(squatter)

      assert {:ok, signed_in} = magic_sign_in(squatter)

      # The session the link mints survives the takeover's sweep, and is not
      # held at a code prompt only the stranger could answer.
      assert token_live?(signed_in.__metadata__.token)
      refute Accounts.totp_enabled?(signed_in)

      row = Repo.reload!(signed_in)
      assert %DateTime{} = row.confirmed_at
      assert row.name == nil
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_pending_secret == nil
      assert row.totp_recovery_hashes == []

      # The stranger's password, session, passkey and key are all dead.
      assert {:error, _} = sign_in(squatter.email, @old_password)
      refute token_live?(stranger_session)

      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(
                 WebAuthn.authentication_challenge(),
                 assertion(passkey_bytes(passkey))
               )

      assert identities(squatter.id) == 0
      assert Accounts.list_push_subscriptions!(squatter.id, actor: admin) == []
      assert :error = Accounts.actor_from_api_key(plaintext(key))

      assert [factor] = events(admin, squatter.id, :second_factor_removed)
      assert factor.metadata == %{"kind" => "totp", "via" => "magic_link"}
      assert [removed] = events(admin, squatter.id, :passkey_removed)
      assert removed.metadata == %{"name" => passkey.name, "via" => "magic_link"}

      # The owner sets a password of their own with a reset.
      assert {:ok, _} = reset_password(row)
      assert {:ok, _} = sign_in(squatter.email, @new_password)
    end

    test "a second magic-link sign-in to the now confirmed account changes nothing" do
      squatter = squatter!()
      assert {:ok, first} = magic_sign_in(squatter)
      hash = Repo.reload!(first).hashed_password

      assert {:ok, second} = magic_sign_in(Repo.reload!(first))
      assert token_live?(first.__metadata__.token)
      assert Repo.reload!(second).hashed_password == hash
    end

    test "is system-only: an actor-carrying call is refused", %{admin: admin} do
      squatter = squatter!()

      assert {:error, _} =
               Accounts.take_over_by_magic_link(squatter, %{token: "x"}, actor: admin)

      assert {:error, _} =
               Accounts.take_over_by_magic_link(squatter, %{token: "x"}, actor: squatter)

      assert Repo.reload!(squatter).confirmed_at == nil
    end
  end

  describe "a magic-link sign-in to a confirmed account" do
    test "keeps its password and every factor", %{admin: admin} do
      owner = enroll_totp!(user(:viewer))
      {:ok, _passkey} = enroll(owner, "owner-cred-#{uniq()}")
      session = session!(owner)

      assert {:ok, signed_in} = magic_sign_in(owner)
      assert Accounts.totp_enabled?(signed_in)

      row = Repo.reload!(signed_in)
      assert row.hashed_password == owner.hashed_password
      assert row.totp_secret == owner.totp_secret
      assert [_] = Accounts.list_passkeys!(owner.id, actor: admin)
      assert token_live?(session)
      assert {:ok, _} = sign_in(owner.email, @old_password)
    end
  end

  describe "erasure" do
    test "clears the TOTP columns, even from a struct read before the enrollment",
         %{admin: admin} do
      stale = user(:viewer)
      enroll_totp!(stale)
      assert stale.totp_secret == nil

      assert {:ok, erased} = Accounts.anonymize_user(stale, actor: admin)

      row = Repo.reload!(erased)
      assert %DateTime{} = row.anonymized_at
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_pending_secret == nil
      assert row.totp_recovery_hashes == []
    end
  end
end
