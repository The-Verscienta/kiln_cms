defmodule KilnCMS.Accounts.RegisterWithInvitationTest do
  @moduledoc """
  Accepting a site invitation (#2135), at the action:

    * no account: `User.:register_with_invitation` creates a confirmed
      `:viewer` with the invited membership, mails no confirmation and consumes
      the invitation — in invite-only mode too;
    * an unconfirmed account (perhaps a stranger's): the invitee's new
      password replaces the old one, which then signs nobody in, and every
      token the account held is revoked;
    * a confirmed account: `Invitation.:accept_existing` adds the membership
      and changes nothing on the account.

  Each refuses a made-up, expired, revoked or used token, an actor-carrying
  call, and an admin invitation whose sender is no longer a standing admin.

  `async: false`: two tests flip `:registration_enabled` and the breached-
  password stub with `Application.put_env`, which is node-wide.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import KilnCMS.BreachedPasswordFixtures, only: [enable!: 2, ok: 2, breached_body: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @moduletag :capture_log

  @password "invitee-password-123"
  @old_password "squatter-password-456"

  defp uniq, do: System.unique_integer([:positive])
  defp address, do: "rwi-#{uniq()}@example.com"

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

  defp invite!(attrs \\ %{}) do
    admin = Map.get(attrs, :admin) || user(:admin)

    invitation =
      Accounts.invite_to_org!(
        Map.merge(
          %{organization_id: Accounts.default_org_id(), email: address(), role: :editor},
          Map.delete(attrs, :admin)
        ),
        actor: admin
      )

    # The invitation mail is not what these tests are about.
    drain_oban()
    flush_emails()
    {invitation, invitation.__metadata__.token}
  end

  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp register(token, extra \\ %{}, opts \\ [authorize?: false]) do
    Accounts.register_with_invitation(
      Map.merge(%{token: token, password: @password, password_confirmation: @password}, extra),
      opts
    )
  end

  defp signs_in?(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    match?(
      {:ok, _},
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(email), "password" => password},
        []
      )
    )
  end

  defp memberships(user_id) do
    Map.new(
      Accounts.list_memberships_for_user!(user_id, authorize?: false),
      &{&1.organization_id, &1}
    )
  end

  defp expire!(invitation) do
    Ash.Seed.update!(invitation, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)})
  end

  describe "a new account" do
    test "is a confirmed viewer holding the invited tier and custom role on the invited site" do
      admin = user(:admin)
      site = org("invited")
      role = Accounts.create_role!(%{name: "Blog #{uniq()}", org_id: site.id}, actor: admin)

      {invitation, token} =
        invite!(%{admin: admin, organization_id: site.id, role: :editor, role_id: role.id})

      assert {:ok, user} = register(token, %{name: "New Person"})

      assert to_string(user.email) == to_string(invitation.email)
      assert user.role == :viewer
      assert user.name == "New Person"
      assert %DateTime{} = Repo.reload!(user).confirmed_at

      membership = memberships(user.id)[site.id]
      assert membership.role == :editor
      assert membership.role_id == role.id

      assert Invitations.peek(token) == nil
      assert Accounts.list_invitations_for_org!(site.id, actor: admin) == []
      assert signs_in?(user.email, @password)
    end

    test "gets no membership on the default site when invited to another one" do
      site = org("invited-only")
      {_invitation, token} = invite!(%{organization_id: site.id, role: :editor})

      assert {:ok, user} = register(token)
      assert Map.keys(memberships(user.id)) == [site.id]
    end

    test "sends no confirmation mail" do
      {_invitation, token} = invite!()
      assert {:ok, _user} = register(token)
      drain_oban()
      refute_email_sent()
    end

    test "takes the address from the invitation, never from input" do
      {invitation, token} = invite!()

      assert {:error, %Ash.Error.Invalid{}} = register(token, %{email: "attacker@example.com"})
      assert {:ok, user} = register(token)
      assert to_string(user.email) == to_string(invitation.email)
    end

    test "a made-up, expired, revoked or used token is refused alike" do
      admin = user(:admin)
      {_used_invitation, used} = invite!(%{admin: admin})
      {:ok, _} = register(used)

      {expired_invitation, expired} = invite!(%{admin: admin})
      expire!(expired_invitation)

      {revoked_invitation, revoked} = invite!(%{admin: admin})
      :ok = Accounts.revoke_invitation(revoked_invitation, actor: admin)

      for token <- [Invitations.generate_token(), used, expired, revoked] do
        assert {:error, error} = register(token)
        assert InvitationRefused.in?(error, :invalid)
      end
    end

    test "a second accept of one link fails and creates nothing more" do
      {invitation, token} = invite!()
      assert {:ok, _} = register(token)
      assert {:error, error} = register(token)
      assert InvitationRefused.in?(error, :invalid)

      assert [_one] =
               Repo.all(
                 from u in "users", where: u.email == ^to_string(invitation.email), select: u.id
               )
    end

    test "refuses any call that carries an actor, an admin's included" do
      {_invitation, token} = invite!()
      admin = user(:admin)

      # Refused before the policy is even asked: the change sees the actor.
      assert {:error, error} = register(token, %{}, actor: admin)
      assert InvitationRefused.in?(error, :invalid)

      assert {:error, error} = register(token, %{}, actor: admin, authorize?: false)
      assert InvitationRefused.in?(error, :invalid)

      assert Invitations.peek(token)
    end

    test "works in invite-only mode" do
      previous = Application.get_env(:kiln_cms, :registration_enabled)
      Application.put_env(:kiln_cms, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, :registration_enabled),
          else: Application.put_env(:kiln_cms, :registration_enabled, previous)
      end)

      {_invitation, token} = invite!()
      assert {:ok, %User{}} = register(token)
    end

    # `:block` binds the admin tier (`PasswordPolicy`), and the tier checked is
    # the invited one.
    test "a breached password for an invited admin is refused under :block, and the invitation stays usable" do
      {_invitation, token} = invite!(%{role: :admin})
      password = KilnCMS.BreachedPasswordFixtures.password()
      enable!(&ok(&1, breached_body(password, 9)), default_policy: :block)

      assert {:error, %Ash.Error.Invalid{} = error} =
               register(token, %{password: password, password_confirmation: password})

      assert Enum.any?(error.errors, &(&1.field == :password))
      assert Invitations.peek(token)
    end

    test "a mismatched confirmation is refused and consumes nothing" do
      {_invitation, token} = invite!()

      assert {:error, %Ash.Error.Invalid{}} =
               register(token, %{password_confirmation: "different-123"})

      assert Invitations.peek(token)
    end
  end

  describe "an admin invitation" do
    test "is refused once its sender is no longer a standing admin" do
      inviter = user(:admin)
      {_invitation, token} = invite!(%{admin: inviter, role: :admin})

      # Demoted (the seed sidesteps the last-admin guard, which is not under test).
      Ash.Seed.update!(inviter, %{role: :editor})

      assert {:error, error} = register(token)
      assert InvitationRefused.in?(error, :invalid)
    end

    test "is honoured while its sender still is one" do
      {_invitation, token} = invite!(%{role: :admin})
      assert {:ok, user} = register(token)
      assert memberships(user.id)[Accounts.default_org_id()].role == :admin
    end
  end

  describe "an unconfirmed account (a stranger may have registered the address)" do
    test "the invitee's password replaces the stranger's and every old token is revoked" do
      {invitation, token} = invite!()

      squatter =
        user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil, name: "Mallory"})

      {:ok, _session, %{"jti" => jti}} = AshAuthentication.Jwt.token_for_user(squatter)
      assert signs_in?(squatter.email, @old_password)

      assert {:ok, accepted} =
               Accounts.accept_invitation_with_password(
                 squatter,
                 %{token: token, password: @password, password_confirmation: @password},
                 authorize?: false
               )

      assert accepted.id == squatter.id
      assert %DateTime{} = Repo.reload!(accepted).confirmed_at
      # No name given: the stranger's byline is cleared, not inherited.
      assert Repo.reload!(accepted).name == nil
      refute signs_in?(squatter.email, @old_password)
      assert signs_in?(squatter.email, @password)

      subject = AshAuthentication.user_to_subject(squatter)

      assert Repo.one(
               from t in "tokens",
                 where: t.jti == ^jti and t.subject == ^subject,
                 select: t.purpose
             ) == "revocation"

      assert memberships(squatter.id)[Accounts.default_org_id()].role == :editor
      assert Invitations.peek(token) == nil
    end

    test "only for the invited address's own unconfirmed account" do
      {_invitation, token} = invite!()
      someone_else = user(:viewer, %{confirmed_at: nil})

      assert {:error, error} =
               Accounts.accept_invitation_with_password(
                 someone_else,
                 %{token: token, password: @password, password_confirmation: @password},
                 authorize?: false
               )

      assert InvitationRefused.in?(error, :invalid)
      assert Invitations.peek(token)
    end

    test "never over a confirmed account" do
      {invitation, token} = invite!()
      owner = user(:viewer, %{email: to_string(invitation.email)})

      assert {:error, error} =
               Accounts.accept_invitation_with_password(
                 owner,
                 %{token: token, password: @password, password_confirmation: @password},
                 authorize?: false
               )

      assert InvitationRefused.in?(error, :invalid)
      assert signs_in?(owner.email, @old_password)
    end
  end

  describe "a confirmed account" do
    test "gets the membership with one click and keeps its password" do
      site = org("existing")
      {invitation, token} = invite!(%{organization_id: site.id, role: :editor})
      owner = user(:viewer, %{email: to_string(invitation.email)})

      assert {:ok, :accepted} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert memberships(owner.id)[site.id].role == :editor
      assert Repo.reload!(owner).hashed_password == owner.hashed_password
      assert Invitations.peek(token) == nil

      assert {:error, error} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert InvitationRefused.in?(error, :invalid)
    end

    test "already a member: the invitation is used up and the membership left alone" do
      site = org("already")
      {invitation, token} = invite!(%{organization_id: site.id, role: :admin})
      owner = user(:viewer, %{email: to_string(invitation.email)})

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: site.id,
        user_id: owner.id,
        role: :viewer
      })

      assert {:ok, :accepted} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert memberships(owner.id)[site.id].role == :viewer
      assert Invitations.peek(token) == nil
    end

    test "an unconfirmed account cannot take the one-click path" do
      {invitation, token} = invite!()
      user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})

      assert {:error, error} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert InvitationRefused.in?(error, :invalid)
      assert Invitations.peek(token)
    end

    test "an admin invitation from a demoted sender is refused" do
      inviter = user(:admin)
      {invitation, token} = invite!(%{admin: inviter, role: :admin})
      user(:viewer, %{email: to_string(invitation.email)})
      Ash.Seed.update!(inviter, %{role: :viewer})

      assert {:error, error} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert InvitationRefused.in?(error, :invalid)
    end
  end
end
