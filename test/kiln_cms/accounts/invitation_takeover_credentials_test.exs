defmodule KilnCMS.Accounts.InvitationTakeoverCredentialsTest do
  @moduledoc """
  Accepting a site invitation over an unconfirmed account forgets every
  credential whoever registered the address first may have set up on it
  (#2453, `Changes.ForgetPriorCredentials`): two-step verification and its
  recovery codes, passkeys, identity-provider links, push devices and API
  keys. The invitee signs in with their new password alone.

  Also: the factors are read from the row, not the struct the caller passed;
  a failure rolls the whole accept back; a confirmed account's one-click
  accept keeps everything; and the actions the takeover uses are the
  invitations system actor's alone.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.PasskeyFixtures, only: [enroll: 2, assertion: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Changes.ForgetPriorCredentials
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.UserIdentity
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.SystemActor

  @moduletag :capture_log

  @password "invitee-password-123"
  @old_password "squatter-password-456"
  @recovery_code "ABCD-EFGH"

  defp uniq, do: System.unique_integer([:positive])
  defp address, do: "takeover-#{uniq()}@example.com"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address(),
          hashed_password: Bcrypt.hash_pwd_salt(@old_password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp invite!(admin) do
    invitation =
      Accounts.invite_to_org!(
        %{organization_id: Accounts.default_org_id(), email: address(), role: :editor},
        actor: admin
      )

    {invitation, invitation.__metadata__.token}
  end

  defp squatter!(invitation),
    do: user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})

  defp accept(user, token, opts \\ []) do
    Accounts.accept_invitation_with_password(
      user,
      %{token: token, password: @password, password_confirmation: @password},
      Keyword.merge([authorize?: false], opts)
    )
  end

  # The stranger's second factor: a confirmed TOTP secret, one recovery code,
  # and a re-enrolment staged and never confirmed.
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

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(
      strategy,
      :sign_in,
      %{"email" => to_string(email), "password" => password},
      []
    )
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

  setup do
    %{admin: user(:admin)}
  end

  describe "an unconfirmed account taken over by an invitation" do
    test "loses every credential the stranger set up, and the invitee signs in with the password alone",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      squatter = invitation |> squatter!() |> enroll_totp!()
      {:ok, passkey} = enroll(squatter, "stranger-cred-#{uniq()}")
      identity!(squatter)
      device!(squatter)
      key = key!(squatter, admin)

      # The gate's own predicate: before the accept, the stranger's factor
      # would hold any sign-in at the code prompt. No site setting requires a
      # second factor by tier, so this is the whole decision.
      assert {:ok, before} = sign_in(squatter.email, @old_password)
      assert Accounts.totp_enabled?(before)

      assert {:ok, accepted} = accept(squatter, token)
      assert accepted.__metadata__[:forgotten_credentials] == true

      row = Repo.reload!(accepted)
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_pending_secret == nil
      assert row.totp_recovery_hashes == []

      # The new password signs in with no second-factor hold; the old one does
      # not sign in at all.
      assert {:ok, signed_in} = sign_in(squatter.email, @password)
      refute Accounts.totp_enabled?(signed_in)
      assert {:error, _} = sign_in(squatter.email, @old_password)

      # Neither the stranger's recovery code nor their passkey gets in.
      assert SecondFactor.check(row, @recovery_code) == :invalid

      assert {:error, :unknown_credential} =
               WebAuthn.authenticate(
                 WebAuthn.authentication_challenge(),
                 assertion(passkey_bytes(passkey))
               )

      assert Accounts.list_passkeys!(squatter.id, actor: admin) == []
      assert identities(squatter.id) == 0
      assert Accounts.list_push_subscriptions!(squatter.id, actor: admin) == []

      # The admin-minted key the stranger held neither authenticates nor rotates.
      assert :error = Accounts.actor_from_api_key(plaintext(key))
      assert %DateTime{} = Accounts.get_api_key!(key.id, actor: admin).revoked_at

      # On the record, with no actor: the system removed them.
      assert [factor] = events(admin, squatter.id, :second_factor_removed)
      assert factor.actor_id == nil
      assert factor.metadata == %{"kind" => "totp", "via" => "invitation"}

      assert [removed] = events(admin, squatter.id, :passkey_removed)
      assert removed.actor_id == nil
      assert removed.metadata == %{"name" => passkey.name, "via" => "invitation"}

      assert [_revoked] =
               Enum.filter(
                 Security.list_events!(actor: admin, tenant: Accounts.default_org_id()),
                 &(&1.type == :api_key_revoked and &1.target_id == key.id and is_nil(&1.actor_id))
               )
    end

    test "reads the factors from the row, not the struct it was handed", %{admin: admin} do
      {invitation, token} = invite!(admin)
      # The caller's read, before the stranger enrolled anything.
      stale = squatter!(invitation)

      enroll_totp!(stale)
      {:ok, _passkey} = enroll(stale, "late-cred-#{uniq()}")

      assert stale.totp_confirmed_at == nil
      assert {:ok, accepted} = accept(stale, token)
      assert accepted.__metadata__[:forgotten_credentials] == true

      row = Repo.reload!(accepted)
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_recovery_hashes == []
      assert Accounts.list_passkeys!(stale.id, actor: admin) == []
      assert [_] = events(admin, stale.id, :second_factor_removed)
    end

    test "with nothing to forget: reports nothing and records nothing", %{admin: admin} do
      {invitation, token} = invite!(admin)
      squatter = squatter!(invitation)

      assert {:ok, accepted} = accept(squatter, token)
      assert accepted.__metadata__[:forgotten_credentials] == false
      assert events(admin, squatter.id, :second_factor_removed) == []
      assert events(admin, squatter.id, :passkey_removed) == []
    end

    test "a failure rolls the whole accept back: password, invitation and credentials stay",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      squatter = invitation |> squatter!() |> enroll_totp!()
      {:ok, _passkey} = enroll(squatter, "kept-cred-#{uniq()}")
      device!(squatter)
      key = key!(squatter, admin)

      # The declared change runs first and removes everything; a second
      # instance appended after it fails, as a refused write would.
      assert {:error, _} =
               squatter
               |> Ash.Changeset.for_update(
                 :accept_invitation_with_password,
                 %{token: token, password: @password, password_confirmation: @password},
                 authorize?: false
               )
               |> ForgetPriorCredentials.change(
                 [remove: fn _changeset, _user, _opts -> {:error, :refused} end],
                 %{}
               )
               |> Ash.update(authorize?: false)

      row = Repo.reload!(squatter)
      assert row.totp_confirmed_at
      assert row.totp_recovery_hashes != []
      assert row.confirmed_at == nil
      assert {:ok, _} = sign_in(squatter.email, @old_password)
      assert Invitations.peek(token)
      assert [_] = Accounts.list_passkeys!(squatter.id, actor: admin)
      assert [_] = Accounts.list_push_subscriptions!(squatter.id, actor: admin)
      assert {:ok, _} = Accounts.actor_from_api_key(plaintext(key))
      assert events(admin, squatter.id, :second_factor_removed) == []
      assert events(admin, squatter.id, :passkey_removed) == []
    end
  end

  describe "a request the stranger's session had in flight (#2453)" do
    # The stranger's request loaded the account before the takeover; each
    # lands after it, acting as the struct it loaded.

    defp taken_over?(result),
      do:
        match?({:error, %Ash.Error.Invalid{}}, result) and
          Enum.any?(
            elem(result, 1).errors,
            &match?(%KilnCMS.Accounts.Errors.AccountTakenOver{}, &1)
          )

    defp subscribe(actor) do
      Accounts.subscribe_to_push(
        %{
          user_id: actor.id,
          endpoint: "https://push.example.com/#{uniq()}",
          p256dh: "p256dh",
          auth: "auth"
        },
        actor: actor
      )
    end

    defp invitee(squatter), do: Accounts.get_user!(squatter.id, authorize?: false)

    test "a passkey registration is refused, and the invitee's own still works",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      stale = squatter!(invitation)

      assert {:ok, _} = accept(stale, token)

      assert taken_over?(enroll(stale, "in-flight-cred-#{uniq()}"))
      assert Accounts.list_passkeys!(stale.id, actor: admin) == []

      assert {:ok, _} = enroll(invitee(stale), "invitee-cred-#{uniq()}")
      assert [_] = Accounts.list_passkeys!(stale.id, actor: admin)
    end

    test "a push subscription is refused, and the invitee's own still works",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      stale = squatter!(invitation)

      assert {:ok, _} = accept(stale, token)

      assert taken_over?(subscribe(stale))
      assert Accounts.list_push_subscriptions!(stale.id, actor: admin) == []

      assert {:ok, _} = subscribe(invitee(stale))
      assert [_] = Accounts.list_push_subscriptions!(stale.id, actor: admin)
    end

    test "a two-step confirmation built before the takeover is refused after it",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      squatter = squatter!(invitation)
      {:ok, staged} = Accounts.setup_totp(squatter, actor: squatter)
      code = Totp.code_at(staged.totp_pending_secret, System.os_time(:second))

      # Built, and its staged secret read, before the takeover commits.
      confirm =
        Ash.Changeset.for_update(staged, :confirm_totp, %{code: code}, actor: staged)

      assert confirm.valid?
      assert {:ok, _} = accept(squatter, token)

      # `Ash.update/1`, not `Accounts.confirm_totp/3`: the code interface would
      # build the changeset again, re-reading the staged secret after the
      # change, and the point is a changeset built before it.
      assert taken_over?(Ash.update(confirm))

      row = Repo.reload!(squatter)
      assert row.totp_secret == nil
      assert row.totp_confirmed_at == nil
      assert row.totp_pending_secret == nil
    end

    test "a password change from the stranger's open settings page is refused",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      stale = squatter!(invitation)

      assert {:ok, _} = accept(stale, token)

      assert taken_over?(
               Accounts.change_password(
                 stale,
                 %{
                   current_password: @old_password,
                   password: "stranger-again-789",
                   password_confirmation: "stranger-again-789"
                 },
                 actor: stale
               )
             )

      assert {:ok, _} = sign_in(stale.email, @password)
      assert {:error, _} = sign_in(stale.email, "stranger-again-789")
    end

    test "the invitee's own password change still works", %{admin: admin} do
      {invitation, token} = invite!(admin)
      assert {:ok, _} = accept(squatter!(invitation), token)
      invitee = Accounts.get_user_by_email!(to_string(invitation.email), authorize?: false)

      assert {:ok, _} =
               Accounts.change_password(
                 invitee,
                 %{
                   current_password: @password,
                   password: "invitee-next-789",
                   password_confirmation: "invitee-next-789"
                 },
                 actor: invitee
               )

      assert {:ok, _} = sign_in(invitee.email, "invitee-next-789")
    end

    test "recovery codes regenerated from the stranger's stale factor are refused",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      stale = invitation |> squatter!() |> enroll_totp!()
      code = Totp.code_at(stale.totp_secret, System.os_time(:second))

      assert {:ok, _} = accept(stale, token)

      assert taken_over?(
               Accounts.regenerate_totp_recovery_codes(stale, %{code: code}, actor: stale)
             )

      assert Repo.reload!(stale).totp_recovery_hashes == []
    end

    test "a confirmation of a secret still staged goes through" do
      user = user(:viewer)
      {:ok, staged} = Accounts.setup_totp(user, actor: user)
      code = Totp.code_at(staged.totp_pending_secret, System.os_time(:second))

      assert {:ok, confirmed} = Accounts.confirm_totp(staged, %{code: code}, actor: staged)
      assert Accounts.totp_enabled?(confirmed)
    end

    test "a confirmation whose staged secret was replaced since it was read is refused" do
      user = user(:viewer)
      {:ok, staged} = Accounts.setup_totp(user, actor: user)
      code = Totp.code_at(staged.totp_pending_secret, System.os_time(:second))
      confirm = Ash.Changeset.for_update(staged, :confirm_totp, %{code: code}, actor: staged)

      # A second tab stages a newer secret between the build and the write.
      {:ok, _} = Accounts.setup_totp(staged, actor: staged)

      # `Ash.update/1`, not `Accounts.confirm_totp/3`: the code interface would
      # build the changeset again, re-reading the staged secret after the
      # change, and the point is a changeset built before it.
      assert taken_over?(Ash.update(confirm))
      refute Accounts.totp_enabled?(Repo.reload!(user))
    end
  end

  describe "a confirmed account's one-click accept" do
    test "keeps its factors, passkeys, devices and keys, and records no removal",
         %{admin: admin} do
      {invitation, token} = invite!(admin)
      owner = user(:viewer, %{email: to_string(invitation.email)}) |> enroll_totp!()
      {:ok, _passkey} = enroll(owner, "owner-cred-#{uniq()}")
      device!(owner)
      key = key!(owner, admin)

      assert {:ok, %{outcome: :joined}} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      row = Repo.reload!(owner)
      assert row.totp_confirmed_at
      assert row.totp_recovery_hashes == owner.totp_recovery_hashes
      assert [_] = Accounts.list_passkeys!(owner.id, actor: admin)
      assert [_] = Accounts.list_push_subscriptions!(owner.id, actor: admin)
      assert {:ok, _} = Accounts.actor_from_api_key(plaintext(key))
      assert events(admin, owner.id, :second_factor_removed) == []
      assert events(admin, owner.id, :passkey_removed) == []
    end
  end

  describe "the takeover's actions" do
    setup %{admin: admin} do
      owner = user(:viewer, %{confirmed_at: nil})
      {:ok, passkey} = enroll(owner, "policy-cred-#{uniq()}")

      %{
        owner: owner,
        passkey: passkey,
        identity: identity!(owner),
        device: device!(owner),
        key: key!(owner, admin)
      }
    end

    defp refused?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

    defp invitations, do: SystemActor.new(:invitations)

    test "are the invitations system actor's", ctx do
      opts = [actor: invitations(), authorize_with: :error]

      assert {:ok, [_]} = Accounts.list_passkeys(ctx.owner.id, opts)
      assert {:ok, [_]} = Accounts.list_user_identities_for_takeover(ctx.owner.id, opts)
      assert {:ok, [_]} = Accounts.list_push_subscriptions(ctx.owner.id, opts)
      assert {:ok, [_]} = Accounts.list_api_keys(ctx.owner.id, opts)

      assert :ok = Accounts.forget_passkey_on_takeover(ctx.passkey, actor: invitations())
      assert :ok = Accounts.forget_user_identity_on_takeover(ctx.identity, actor: invitations())

      assert :ok =
               Accounts.forget_push_subscription_on_takeover(ctx.device, actor: invitations())

      assert {:ok, _} = Accounts.revoke_api_key(ctx.key, actor: invitations())
    end

    test "refuse the account's owner, a platform admin and every other subsystem", ctx do
      for actor <- [
            ctx.owner,
            ctx.admin,
            SystemActor.new(:push),
            SystemActor.new(:registrations)
          ] do
        assert refused?(Accounts.forget_passkey_on_takeover(ctx.passkey, actor: actor)),
               "passkey forget admitted #{inspect(actor.__struct__)}"

        assert refused?(Accounts.forget_user_identity_on_takeover(ctx.identity, actor: actor))

        assert refused?(Accounts.forget_push_subscription_on_takeover(ctx.device, actor: actor))

        assert refused?(
                 Accounts.list_user_identities_for_takeover(ctx.owner.id,
                   actor: actor,
                   authorize_with: :error
                 )
               )
      end

      for actor <- [SystemActor.new(:push), SystemActor.new(:registrations)] do
        assert refused?(
                 Accounts.list_passkeys(ctx.owner.id, actor: actor, authorize_with: :error)
               )

        assert refused?(
                 Accounts.list_push_subscriptions(ctx.owner.id,
                   actor: actor,
                   authorize_with: :error
                 )
               )

        assert refused?(
                 Accounts.list_api_keys(ctx.owner.id, actor: actor, authorize_with: :error)
               )

        assert refused?(Accounts.revoke_api_key(ctx.key, actor: actor))
      end
    end

    test "grant the invitations system actor nothing more than the takeover needs", ctx do
      assert refused?(Accounts.remove_passkey(ctx.passkey, actor: invitations()))
      assert refused?(Accounts.remove_push_subscription(ctx.device, actor: invitations()))

      assert refused?(
               Accounts.push_subscriptions_for([ctx.owner.id],
                 actor: invitations(),
                 authorize_with: :error
               )
             )

      assert refused?(Accounts.list_all_api_keys(actor: invitations(), authorize_with: :error))
    end
  end

  # The raw credential id the stub ceremony stored, for an assertion payload.
  defp passkey_bytes(passkey), do: Base.url_decode64!(passkey.credential_id, padding: false)
end
