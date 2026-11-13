defmodule KilnCMS.Accounts.InvitationTest do
  @moduledoc """
  The site invitation resource (#2135): inviting mails one link whose token
  matches only the stored hash; resend rotates it, revoke kills it, expiry
  hides it; only a standing platform admin can do any of it; the system-only
  lookups refuse an actor; the daily prune removes rows long past expiry.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])
  defp address, do: "invitee-#{uniq()}@example.com"
  defp default_org, do: Accounts.default_org_id()

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "inv-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp invite!(admin, attrs \\ %{}) do
    Accounts.invite_to_org!(
      Map.merge(%{organization_id: default_org(), email: address(), role: :editor}, attrs),
      actor: admin
    )
  end

  defp expire!(invitation, days_ago \\ 1) do
    Ash.Seed.update!(invitation, %{
      expires_at: DateTime.add(DateTime.utc_now(), -days_ago, :day)
    })
  end

  # The token in the one invitation mail sent to `email`.
  defp mailed_token(email) do
    drain_oban()

    assert_email_sent(fn mail ->
      send(self(), {:body, mail.html_body})
      mail.to == [{"", email}]
    end)

    assert_received {:body, body}
    [_, token] = Regex.run(~r{/auth/invite/([A-Za-z0-9_-]+)}, body)
    token
  end

  describe "invite" do
    test "creates the row and mails one link whose token matches only the stored hash" do
      admin = user(:admin)
      email = address()
      invitation = invite!(admin, %{email: email})

      token = mailed_token(email)
      assert token == invitation.__metadata__.token
      assert invitation.token_hash == Invitations.hash(token)
      refute invitation.token_hash == token
      assert invitation.invited_by_id == admin.id
      assert invitation.sent_count == 1
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) in 6..7

      assert %Invitation{id: id} = Invitations.peek(token)
      assert id == invitation.id
      assert Invitations.peek(token <> "x") == nil
    end

    test "the mail names the site and the tier, and the link opens on the site's host" do
      admin = user(:admin)
      email = address()
      invite!(admin, %{email: email, role: :editor})
      drain_oban()

      assert_email_sent(fn mail ->
        assert mail.subject =~ "invited"
        assert mail.html_body =~ "as an editor"
        assert mail.html_body =~ ~r{href="https?://[^/"]+/auth/invite/}
        mail.to == [{"", email}]
      end)
    end

    test "a second live invitation for the same address on the same site is refused" do
      admin = user(:admin)
      email = address()
      invite!(admin, %{email: email})

      assert {:error, error} =
               Accounts.invite_to_org(
                 %{organization_id: default_org(), email: String.upcase(email)},
                 actor: admin
               )

      assert Exception.message(error) =~ Invitation.pending_message()
    end

    test "the same address may be invited to two different sites" do
      admin = user(:admin)
      email = address()
      invite!(admin, %{email: email})
      assert %Invitation{} = invite!(admin, %{email: email, organization_id: org("other").id})
    end

    test "an address the mail queue would refuse is a form error, not a crash" do
      admin = user(:admin)

      for bad <- ["no-at-sign", "two@@example.com", "a@b@c", "x@exa mple.com", "@example.com"] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Accounts.invite_to_org(%{organization_id: default_org(), email: bad},
                   actor: admin
                 ),
               "expected #{inspect(bad)} to be refused"

        assert Enum.any?(error.errors, &(&1.field == :email))
      end

      long = String.duplicate("a", 250) <> "@example.com"

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.invite_to_org(%{organization_id: default_org(), email: long},
                 actor: admin
               )

      assert Accounts.list_invitations_for_org!(default_org(), actor: admin) == []
    end

    test "a custom role of another site is refused" do
      admin = user(:admin)
      foreign = org("foreign")

      role =
        Accounts.create_role!(%{name: "Foreign #{uniq()}", org_id: foreign.id}, actor: admin)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.invite_to_org(
                 %{organization_id: default_org(), email: address(), role_id: role.id},
                 actor: admin
               )

      assert Enum.any?(error.errors, &(&1.field == :role_id))
    end

    test "an address on the suppression list is refused by name, and nothing is sent" do
      admin = user(:admin)
      email = address()
      Ash.Seed.seed!(KilnCMS.Mail.SuppressedRecipient, %{email: email})

      assert {:error, error} =
               Accounts.invite_to_org(%{organization_id: default_org(), email: email},
                 actor: admin
               )

      assert InvitationRefused.in?(error, :suppressed)
      drain_oban()
      refute_email_sent()
    end

    test "records an audit event in the invited site's log, without the address" do
      admin = user(:admin)
      site = org("audited")
      email = address()
      invitation = invite!(admin, %{email: email, organization_id: site.id, role: :viewer})

      [event] =
        KilnCMS.Security.list_events!(actor: admin, tenant: site.id, page: [limit: 50])
        |> Map.get(:results)
        |> Enum.filter(&(&1.type == :member_invited))

      assert event.target_type == "invitation"
      assert event.target_id == invitation.id
      assert event.actor_id == admin.id
      assert event.metadata == %{"role" => "viewer", "resent" => false}
      refute inspect(event.metadata) =~ email
    end
  end

  describe "resend" do
    test "rotates the token: the old link stops working, the new one works" do
      admin = user(:admin)
      invitation = invite!(admin)
      old = invitation.__metadata__.token

      resent = Accounts.resend_invitation!(invitation, %{}, actor: admin)
      new = resent.__metadata__.token

      assert new != old
      assert Invitations.peek(old) == nil
      assert Invitations.peek(new).id == invitation.id
      assert resent.sent_count == 2
      assert resent.role == invitation.role
    end

    test "restarts the clock of an expired invitation" do
      admin = user(:admin)
      invitation = admin |> invite!() |> expire!()
      assert Invitations.peek(invitation.__metadata__.token) == nil

      resent = Accounts.resend_invitation!(invitation, %{}, actor: admin)
      assert DateTime.compare(resent.expires_at, DateTime.utc_now()) == :gt
      assert Invitations.peek(resent.__metadata__.token)
    end
  end

  describe "revoke" do
    test "destroys the row, so its link is dead" do
      admin = user(:admin)
      invitation = invite!(admin)
      token = invitation.__metadata__.token

      :ok = Accounts.revoke_invitation(invitation, actor: admin)
      assert Invitations.peek(token) == nil
      assert Accounts.list_invitations_for_org!(default_org(), actor: admin) == []
    end
  end

  describe "expiry" do
    test "an expired token names nothing" do
      admin = user(:admin)
      invitation = admin |> invite!() |> expire!()
      assert Invitations.peek(invitation.__metadata__.token) == nil
    end
  end

  describe "authorization" do
    setup do
      admin = user(:admin)
      %{admin: admin, invitation: invite!(admin)}
    end

    for role <- [:editor, :viewer] do
      test "#{role}s are refused every action", %{invitation: invitation} do
        actor = user(unquote(role))
        assert_refused_everything(actor, invitation)
      end
    end

    test "a site admin who is not a platform admin is refused", %{invitation: invitation} do
      site_admin = user(:editor)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: default_org(),
        user_id: site_admin.id,
        role: :admin
      })

      assert_refused_everything(site_admin, invitation)
    end

    test "anonymous callers are refused", %{invitation: invitation} do
      assert_refused_everything(nil, invitation)
    end

    test "a temporary platform admin cannot invite or resend", %{invitation: invitation} do
      temp =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.invite_to_org(%{organization_id: default_org(), email: address()},
                 actor: temp
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.resend_invitation(invitation, %{}, actor: temp)
    end

    test "the token lookup, the accept and the consume refuse even an admin",
         %{admin: admin, invitation: invitation} do
      token = invitation.__metadata__.token

      # The read answers nothing rather than the row.
      assert {:ok, nil} =
               Accounts.get_invitation_by_token(token, actor: admin, not_found_error?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.accept_invitation_for_existing_account(token, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.consume_invitation(invitation, actor: admin)

      # Still there, still live.
      assert Invitations.peek(token).id == invitation.id
    end
  end

  defp assert_refused_everything(actor, invitation) do
    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.invite_to_org(%{organization_id: default_org(), email: address()},
               actor: actor
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.add_or_invite_member(%{organization_id: default_org(), email: address()},
               actor: actor
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.resend_invitation(invitation, %{}, actor: actor)

    assert {:error, %Ash.Error.Forbidden{}} = Accounts.revoke_invitation(invitation, actor: actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.list_invitations_for_org(default_org(),
               actor: actor,
               authorize_with: :error
             )

    assert Invitations.peek(invitation.__metadata__.token).id == invitation.id
  end

  describe "the daily prune" do
    test "removes invitations long past expiry and keeps the rest" do
      admin = user(:admin)
      stale = admin |> invite!() |> expire!(Invitations.prune_after_days() + 1)
      recent = admin |> invite!() |> expire!(1)
      live = invite!(admin)

      AshOban.schedule_and_run_triggers(Invitation,
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )

      ids = Enum.map(Accounts.list_invitations_for_org!(default_org(), actor: admin), & &1.id)
      refute stale.id in ids
      assert recent.id in ids
      assert live.id in ids
    end
  end
end

defmodule KilnCMS.Accounts.InvitationBudgetTest do
  @moduledoc """
  The per-address invitation mail budget (#2135) is spent by invites and
  resends, and a refusal is named to the admin rather than dropped.

  `async: false`: it narrows `KilnCMS.Accounts.AccountThrottle`'s mail budget
  with `Application.put_env`, which is node-wide.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.InvitationRefused

  @moduletag :capture_log

  setup do
    original = Application.get_env(:kiln_cms, AccountThrottle, [])
    Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(original, :mail_budget, 2))
    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, original) end)
    :ok
  end

  test "the third send within the window is refused by name" do
    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "budget-admin-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    email = "budget-#{System.unique_integer([:positive])}@example.com"
    on_exit(fn -> AccountThrottle.reset(email) end)

    invitation =
      Accounts.invite_to_org!(%{organization_id: Accounts.default_org_id(), email: email},
        actor: admin
      )

    resent = Accounts.resend_invitation!(invitation, %{}, actor: admin)

    assert {:error, error} = Accounts.resend_invitation(resent, %{}, actor: admin)
    assert InvitationRefused.in?(error, :mail_budget)

    # The refused resend changed nothing: the last mailed link still works.
    assert KilnCMS.Accounts.Invitations.peek(resent.__metadata__.token)
  end
end

defmodule KilnCMS.Accounts.InvitationMailTest do
  @moduledoc """
  The invitation and membership-notice mails (#2135) carry the site name as it
  is in the subject and HTML-escaped only in the body.

  Each test brands its own fresh site, so the branding cache entry it reads is
  its own. A branding read inside a transaction runs on the caller's connection
  (`KilnCMS.Cache.fetch/3`), so the sandbox mode does not matter to it.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @moduletag :capture_log

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "mail-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    admin = user(:admin)
    site = org("rnd")
    CMS.save_site_branding!(%{site_name: "R&D's"}, actor: admin, tenant: site)
    %{admin: admin, site: site}
  end

  test "the invitation's subject is the raw site name; the body escapes it", ctx do
    email = "mail-invitee-#{System.unique_integer([:positive])}@example.com"
    Accounts.invite_to_org!(%{organization_id: ctx.site.id, email: email}, actor: ctx.admin)
    drain_oban()

    assert_email_sent(fn mail ->
      assert mail.subject == "You've been invited to R&D's"
      assert mail.html_body =~ "R&amp;D&#39;s"
      refute mail.html_body =~ "R&D's"
      mail.to == [{"", email}]
    end)
  end

  test "the membership notice's subject is the raw site name; the body escapes it", ctx do
    colleague = user(:viewer)

    {:ok, %{outcome: :added}} =
      Accounts.add_or_invite_member(
        %{organization_id: ctx.site.id, email: to_string(colleague.email)},
        actor: ctx.admin
      )

    drain_oban()

    assert_email_sent(fn mail ->
      assert mail.subject == "You were added to R&D's"
      assert mail.html_body =~ "R&amp;D&#39;s"
      mail.to == [{"", to_string(colleague.email)}]
    end)
  end

  test "an inviter with no display name is \"An administrator\", never their address", ctx do
    email = "mail-invitee-#{System.unique_integer([:positive])}@example.com"
    Accounts.invite_to_org!(%{organization_id: ctx.site.id, email: email}, actor: ctx.admin)
    drain_oban()

    assert_email_sent(fn mail ->
      assert mail.html_body =~ "An administrator invited you"
      refute mail.html_body =~ to_string(ctx.admin.email)
      mail.to == [{"", email}]
    end)
  end
end
