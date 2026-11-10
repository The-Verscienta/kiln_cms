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

  An account already on the invited site is raised to the invited tier when
  it held a lower one, and never lowered (#2452); a person changing that
  member's tier retires the invitation still pending.

  `async: false`: two tests flip `:registration_enabled` and the breached-
  password stub with `Application.put_env`, which is node-wide, and one case
  holds a transaction open in one process while another process accepts, which
  needs the sandbox's shared mode.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query
  import KilnCMS.BreachedPasswordFixtures, only: [enable!: 2, ok: 2, breached_body: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.SystemActor
  alias KilnCMS.Test.Latch

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

  defp member!(user, org_id, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{organization_id: org_id, user_id: user.id, role: role}, attrs)
    )
  end

  defp reload(membership),
    do:
      Accounts.get_org_membership!(membership.user_id, membership.organization_id,
        authorize?: false
      )

  defp accept_existing(token),
    do: Accounts.accept_invitation_for_existing_account(token, authorize?: false)

  defp accept_with_password(user, token),
    do:
      Accounts.accept_invitation_with_password(
        user,
        %{token: token, password: @password, password_confirmation: @password},
        authorize?: false
      )

  defp revocations(org_id, invitation) do
    Security.list_events!(actor: user(:admin), tenant: org_id, page: [limit: 200])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :invitation_revoked and &1.target_id == invitation.id))
  end

  defp role_events(org_id, user, type) do
    Security.list_events!(actor: user(:admin), tenant: org_id, page: [limit: 200])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type and &1.target_id == user.id))
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

      assert {:ok, %{outcome: :joined, role: :editor}} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert memberships(owner.id)[site.id].role == :editor
      assert Repo.reload!(owner).hashed_password == owner.hashed_password
      assert Invitations.peek(token) == nil

      assert {:error, error} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert InvitationRefused.in?(error, :invalid)
    end

    test "already a member below the invited tier: raised to it, and the invitation used up" do
      site = org("already")
      {invitation, token} = invite!(%{organization_id: site.id, role: :admin})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      member!(owner, site.id, :viewer)

      assert {:ok, %{outcome: :raised, role: :admin}} =
               Accounts.accept_invitation_for_existing_account(token, authorize?: false)

      assert memberships(owner.id)[site.id].role == :admin
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

  describe "an account already on the invited site (#2452)" do
    setup do
      %{site: org("raise"), admin: user(:admin)}
    end

    test "an editor invitation over a viewer membership raises it to editor, once, on the record",
         %{site: site, admin: admin} do
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :editor})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :viewer)

      assert {:ok, %{outcome: :raised, role: :editor}} = accept_existing(token)

      assert %{role: :editor, status: :active} = reload(row)
      assert Invitations.peek(token) == nil
      assert Accounts.list_invitations_for_org!(site.id, actor: admin) == []

      # One `role_granted`, in the invited site's own log, naming what it was.
      assert [event] = role_events(site.id, owner, :role_granted)
      assert event.metadata == %{"role" => "editor", "previous_role" => "viewer"}
      assert role_events(site.id, owner, :role_revoked) == []

      # The link is spent.
      assert {:error, error} = accept_existing(token)
      assert InvitationRefused.in?(error, :invalid)
    end

    test "an admin invitation over an editor membership raises it to admin",
         %{site: site, admin: admin} do
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :admin})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :editor)

      assert {:ok, %{outcome: :raised, role: :admin}} = accept_existing(token)
      assert reload(row).role == :admin
    end

    test "an admin invitation from a demoted sender raises nothing", %{site: site} do
      inviter = user(:admin)
      {invitation, token} = invite!(%{admin: inviter, organization_id: site.id, role: :admin})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :editor)
      Ash.Seed.update!(inviter, %{role: :viewer})

      assert {:error, error} = accept_existing(token)
      assert InvitationRefused.in?(error, :invalid)
      assert %{role: :editor} = after_row = reload(row)
      assert after_row.updated_at == row.updated_at
    end

    test "a viewer invitation over an editor membership lowers nothing, and says so",
         %{site: site, admin: admin} do
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :viewer})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :editor)

      assert {:ok, %{outcome: :already_member, role: :editor}} = accept_existing(token)

      assert %{role: :editor} = after_row = reload(row)
      assert after_row.updated_at == row.updated_at
      # Used up all the same: it has nothing left to give.
      assert Invitations.peek(token) == nil
      assert role_events(site.id, owner, :role_granted) == []
      assert role_events(site.id, owner, :role_revoked) == []
    end

    test "an invitation at the tier already held changes nothing",
         %{site: site, admin: admin} do
      role = Accounts.create_role!(%{name: "Desk #{uniq()}", org_id: site.id}, actor: admin)

      {invitation, token} =
        invite!(%{admin: admin, organization_id: site.id, role: :editor, role_id: role.id})

      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :editor)

      assert {:ok, %{outcome: :already_member, role: :editor}} = accept_existing(token)
      # Not even the custom role: an invitation that raises nothing writes nothing.
      assert %{role: :editor, role_id: nil} = after_row = reload(row)
      assert after_row.updated_at == row.updated_at
    end

    test "the standing tier is compared, not a live temporary one, and a grant the raise reaches is cleared",
         %{site: site, admin: admin} do
      until = DateTime.add(DateTime.utc_now(), 1, :day)

      # Standing viewer, admin until tomorrow: an editor invitation raises the
      # standing tier; the grant still outranks it and stays.
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :editor})
      owner = user(:viewer, %{email: to_string(invitation.email)})

      row =
        member!(owner, site.id, :viewer, %{granted_role: :admin, granted_role_expires_at: until})

      assert {:ok, %{outcome: :raised, role: :editor}} = accept_existing(token)

      assert %{role: :editor, granted_role: :admin, granted_role_expires_at: %DateTime{}} =
               reload(row)

      # Standing viewer, editor until tomorrow: an editor invitation raises the
      # standing tier to the grant's, which then says nothing and is cleared.
      other_site = org("raise-grant")
      {other, other_token} = invite!(%{admin: admin, organization_id: other_site.id})
      other_owner = user(:viewer, %{email: to_string(other.email)})

      other_row =
        member!(other_owner, other_site.id, :viewer, %{
          granted_role: :editor,
          granted_role_expires_at: until
        })

      assert {:ok, %{outcome: :raised, role: :editor}} = accept_existing(other_token)

      assert %{role: :editor, granted_role: nil, granted_role_expires_at: nil} =
               reload(other_row)
    end

    test "a made-up, expired, revoked or used token raises nothing, on either path",
         %{site: site, admin: admin} do
      {used_invitation, used} = invite!(%{admin: admin, organization_id: site.id})
      {used_owner, used_row} = lower_member(used_invitation, site)
      {:ok, %{outcome: :raised}} = accept_existing(used)
      Ash.Seed.update!(reload(used_row), %{role: :viewer})

      {expired_invitation, expired} = invite!(%{admin: admin, organization_id: site.id})
      expire!(expired_invitation)
      {expired_owner, _row} = lower_member(expired_invitation, site)

      {revoked_invitation, revoked} = invite!(%{admin: admin, organization_id: site.id})
      :ok = Accounts.revoke_invitation(revoked_invitation, actor: admin)
      {revoked_owner, _row} = lower_member(revoked_invitation, site)

      for {owner, token} <- [
            {used_owner, Invitations.generate_token()},
            {used_owner, used},
            {expired_owner, expired},
            {revoked_owner, revoked}
          ] do
        assert {:error, error} = accept_existing(token)
        assert InvitationRefused.in?(error, :invalid)
        assert memberships(owner.id)[site.id].role == :viewer
      end

      # The password path, over an unconfirmed account holding a lower row.
      {stale, stale_token} = invite!(%{admin: admin, organization_id: site.id})
      expire!(stale)
      squatter = user(:viewer, %{email: to_string(stale.email), confirmed_at: nil})
      member!(squatter, site.id, :viewer)

      assert {:error, error} = accept_with_password(squatter, stale_token)
      assert InvitationRefused.in?(error, :invalid)
      assert memberships(squatter.id)[site.id].role == :viewer
    end

    test "raises the invited site only, whatever the account holds elsewhere",
         %{site: site, admin: admin} do
      elsewhere = org("raise-elsewhere")
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :editor})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      other = member!(owner, elsewhere.id, :viewer)

      assert {:ok, %{outcome: :joined, role: :editor}} = accept_existing(token)

      assert memberships(owner.id)[site.id].role == :editor
      assert %{role: :viewer} = after_row = reload(other)
      assert after_row.updated_at == other.updated_at
    end

    test "an unconfirmed account with a lower row: the password accept raises it and revokes its tokens",
         %{site: site, admin: admin} do
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :editor})
      squatter = user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})
      row = member!(squatter, site.id, :viewer)
      {:ok, _session, %{"jti" => jti}} = AshAuthentication.Jwt.token_for_user(squatter)

      assert {:ok, accepted} = accept_with_password(squatter, token)

      assert accepted.__metadata__.invitation_outcome == %{outcome: :raised, role: :editor}
      assert reload(row).role == :editor
      assert Invitations.peek(token) == nil

      subject = AshAuthentication.user_to_subject(squatter)

      assert Repo.one(
               from t in "tokens",
                 where: t.jti == ^jti and t.subject == ^subject,
                 select: t.purpose
             ) == "revocation"
    end

    test "a new account's password accept reports a join", %{site: site} do
      {_invitation, token} = invite!(%{organization_id: site.id, role: :editor})
      assert {:ok, user} = register(token)
      assert user.__metadata__.invitation_outcome == %{outcome: :joined, role: :editor}
    end

    test "the raise takes the invitation's custom role, keeps the row's when it names none, and keeps every other axis",
         %{site: site, admin: admin} do
      kept = Accounts.create_role!(%{name: "Kept #{uniq()}", org_id: site.id}, actor: admin)
      named = Accounts.create_role!(%{name: "Named #{uniq()}", org_id: site.id}, actor: admin)

      axes = %{
        role_id: kept.id,
        audiences: [:member],
        editable_types: ["post"],
        readable_types: ["post", "page"],
        field_grants: %{"post" => ["title"]},
        field_read_grants: %{"post" => []}
      }

      {plain, plain_token} = invite!(%{admin: admin, organization_id: site.id, role: :editor})
      plain_owner = user(:viewer, %{email: to_string(plain.email)})
      plain_row = member!(plain_owner, site.id, :viewer, axes)

      assert {:ok, %{outcome: :raised}} = accept_existing(plain_token)

      assert %{
               role: :editor,
               audiences: [:member],
               editable_types: ["post"],
               readable_types: ["post", "page"],
               field_grants: %{"post" => ["title"]},
               field_read_grants: %{"post" => []}
             } = raised = reload(plain_row)

      assert raised.role_id == kept.id

      {custom, custom_token} =
        invite!(%{admin: admin, organization_id: site.id, role: :editor, role_id: named.id})

      custom_owner = user(:viewer, %{email: to_string(custom.email)})
      custom_row = member!(custom_owner, site.id, :viewer, axes)

      assert {:ok, %{outcome: :raised}} = accept_existing(custom_token)
      assert reload(custom_row).role_id == named.id
    end
  end

  describe "OrgMembership.:raise_role_by_invitation, called directly" do
    setup do
      site = org("raise-direct")
      owner = user(:viewer)
      %{site: site, owner: owner, row: member!(owner, site.id, :viewer)}
    end

    test "admits the invitations system actor", %{row: row} do
      assert {:ok, %{role: :editor}} =
               Accounts.raise_membership_role_by_invitation(row, %{role: :editor},
                 actor: SystemActor.new(:invitations)
               )
    end

    test "refuses the member, a site admin, and another subsystem",
         %{site: site, owner: owner, row: row} do
      site_admin = user(:viewer)
      member!(site_admin, site.id, :admin)

      for actor <- [owner, site_admin, SystemActor.new(:registrations)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.raise_membership_role_by_invitation(row, %{role: :admin}, actor: actor)
      end

      assert reload(row).role == :viewer
    end

    test "never lowers, judged on the row as locked rather than the struct passed",
         %{row: row} do
      # A site admin raised the row after the caller read it.
      Ash.Seed.update!(row, %{role: :admin})

      assert {:error, error} =
               Accounts.raise_membership_role_by_invitation(row, %{role: :editor},
                 actor: SystemActor.new(:invitations)
               )

      assert InvitationRefused.in?(error, :not_higher)
      assert reload(row).role == :admin
    end

    test "refuses a row that is not active", %{site: site} do
      applicant = user(:viewer)
      pending = member!(applicant, site.id, :viewer, %{status: :pending})

      assert {:error, error} =
               Accounts.raise_membership_role_by_invitation(pending, %{role: :editor},
                 actor: SystemActor.new(:invitations)
               )

      assert InvitationRefused.in?(error, :invalid)
      assert %{status: :pending, role: :viewer} = reload(pending)
    end

    test "refuses another site's custom role", %{row: row} do
      admin = user(:admin)
      foreign = org("raise-foreign")
      role = Accounts.create_role!(%{name: "Foreign #{uniq()}", org_id: foreign.id}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.raise_membership_role_by_invitation(
                 row,
                 %{role: :editor, role_id: role.id},
                 actor: SystemActor.new(:invitations)
               )

      assert reload(row).role == :viewer
    end
  end

  describe "a tier changed by a person retires the invitation still pending (#2452)" do
    setup do
      site = org("retire")
      admin = user(:admin)
      {invitation, token} = invite!(%{admin: admin, organization_id: site.id, role: :admin})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      row = member!(owner, site.id, :editor)

      %{
        site: site,
        admin: admin,
        invitation: invitation,
        token: token,
        owner: owner,
        row: row
      }
    end

    test "a demotion: the old link no longer raises anyone, and the log says it was revoked",
         %{site: site, admin: admin, invitation: invitation, token: token, row: row} do
      assert {:ok, _} = Accounts.update_org_membership(row, %{role: :viewer}, actor: admin)

      assert Invitations.peek(token) == nil
      assert {:error, error} = accept_existing(token)
      assert InvitationRefused.in?(error, :invalid)
      assert reload(row).role == :viewer

      # In the invitation's own site's log, with the admin who demoted as actor.
      assert [event] = revocations(site.id, invitation)
      assert event.actor_id == admin.id
      assert event.metadata == %{"role" => "admin"}
    end

    test "a changed custom role retires it too, on the record",
         %{site: site, admin: admin, invitation: invitation, token: token, row: row} do
      role = Accounts.create_role!(%{name: "Narrow #{uniq()}", org_id: site.id}, actor: admin)
      assert {:ok, _} = Accounts.update_org_membership(row, %{role_id: role.id}, actor: admin)
      assert Invitations.peek(token) == nil
      assert [_one] = revocations(site.id, invitation)
    end

    test "removing the member retires it, on the record",
         %{site: site, admin: admin, invitation: invitation, token: token, row: row} do
      assert :ok = Accounts.remove_org_membership(row, actor: admin)
      assert Invitations.peek(token) == nil
      assert [_one] = revocations(site.id, invitation)
    end

    test "an edit that leaves the tier alone leaves the invitation alone",
         %{site: site, admin: admin, invitation: invitation, token: token, row: row} do
      assert {:ok, _} =
               Accounts.update_org_membership(row, %{audiences: [:member]}, actor: admin)

      assert Invitations.peek(token)
      assert revocations(site.id, invitation) == []
    end

    test "Invitation.:retire is the invitations system actor's alone",
         %{admin: admin, invitation: invitation, token: token} do
      for actor <- [admin, SystemActor.new(:registrations)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.retire_invitation(invitation, actor: actor)
      end

      assert Invitations.peek(token)

      assert :ok =
               Accounts.retire_invitation(invitation, actor: SystemActor.new(:invitations))

      assert Invitations.peek(token) == nil
    end

    test "only the membership's own site: an invitation elsewhere stays",
         %{admin: admin, owner: owner, row: row} do
      elsewhere = org("retire-elsewhere")

      {_other, other_token} =
        invite!(%{
          admin: admin,
          organization_id: elsewhere.id,
          email: to_string(owner.email),
          role: :admin
        })

      assert {:ok, _} = Accounts.update_org_membership(row, %{role: :viewer}, actor: admin)
      assert Invitations.peek(other_token)
    end

    # Under the shared sandbox both tasks use one connection, so this shows the
    # outcome of an accept that arrives while the edit's transaction is open,
    # not that the accept waits on the invitation's row lock.
    test "an accept arriving while an edit that retires the link is in flight finds the link gone",
         %{admin: admin, token: token, row: row} do
      test_pid = self()
      start_supervised!({Latch, name: :retire_race, listener: test_pid})

      # Held inside the edit's transaction, after the invitation is retired
      # and the row written, until the test lets it commit.
      held =
        row
        |> Ash.Changeset.new()
        |> Ash.Changeset.after_action(fn _changeset, record ->
          Latch.enter(:retire_race)
          {:ok, record}
        end)

      edit =
        Task.async(fn -> Accounts.update_org_membership(held, %{role: :viewer}, actor: admin) end)

      assert_receive {:latch_started, :retire_race, 1}, 2_000

      accept = Task.async(fn -> accept_existing(token) end)

      assert [_] = Latch.release_all(:retire_race)
      assert {:ok, %{role: :viewer}} = Task.await(edit)
      assert {:error, error} = Task.await(accept)
      assert InvitationRefused.in?(error, :invalid)
      refute_received {:latch_timeout, _, _}

      assert reload(row).role == :viewer
    end
  end

  defp lower_member(invitation, site) do
    owner = user(:viewer, %{email: to_string(invitation.email)})
    {owner, member!(owner, site.id, :viewer)}
  end
end
