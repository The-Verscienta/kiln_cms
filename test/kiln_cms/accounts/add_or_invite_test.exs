defmodule KilnCMS.Accounts.AddOrInviteTest do
  @moduledoc """
  The Team page's "Add or invite" (#2135): a confirmed account is added at once
  and told so; an existing member is refused; any other address — an
  unconfirmed account included — is invited; a live invitation is refused and
  an expired one is sent again.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])
  defp address, do: "aoi-#{uniq()}@example.com"
  defp default_org, do: Accounts.default_org_id()

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address(),
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp add_or_invite(admin, org_id, email, attrs \\ %{}) do
    Accounts.add_or_invite_member(
      Map.merge(%{organization_id: org_id, email: email}, attrs),
      actor: admin
    )
  end

  describe "an address with a confirmed account" do
    test "is added at once, at the chosen tier, and told by mail" do
      admin = user(:admin)
      colleague = user(:viewer)
      site = org("added")

      assert {:ok, %{outcome: :added, membership: membership}} =
               add_or_invite(admin, site.id, to_string(colleague.email), %{role: :editor})

      assert membership.organization_id == site.id
      assert membership.role == :editor

      drain_oban()

      assert_email_sent(fn mail ->
        mail.to == [{"", to_string(colleague.email)}] and mail.subject =~ "added"
      end)

      assert Accounts.list_invitations_for_org!(site.id, actor: admin) == []
    end

    test "matches the address case-insensitively and trims it" do
      admin = user(:admin)
      colleague = user(:viewer)

      assert {:ok, %{outcome: :added}} =
               add_or_invite(
                 admin,
                 org("case").id,
                 "  " <> String.upcase(to_string(colleague.email)) <> " "
               )
    end

    test "already on another site, it is added here too and keeps the other" do
      admin = user(:admin)
      colleague = user(:viewer)
      first = org("first")
      second = org("second")

      {:ok, %{outcome: :added}} = add_or_invite(admin, first.id, to_string(colleague.email))
      {:ok, %{outcome: :added}} = add_or_invite(admin, second.id, to_string(colleague.email))

      orgs =
        colleague.id
        |> Accounts.list_memberships_for_user!(authorize?: false)
        |> Enum.map(& &1.organization_id)
        |> MapSet.new()

      assert MapSet.subset?(MapSet.new([first.id, second.id]), orgs)
    end

    test "a legacy editor's first membership elsewhere carries its default-site tier first" do
      admin = user(:admin)
      legacy = user(:editor)
      site = org("legacy")

      {:ok, %{outcome: :added}} = add_or_invite(admin, site.id, to_string(legacy.email))

      memberships =
        Map.new(
          Accounts.list_memberships_for_user!(legacy.id, authorize?: false),
          &{&1.organization_id, &1.role}
        )

      assert memberships[default_org()] == :editor
      assert memberships[site.id] == :viewer
    end

    test "a pending invitation for the address on this site goes with the direct add" do
      admin = user(:admin)
      email = address()
      site = org("superseded")
      {:ok, %{outcome: :invited, invitation: invitation}} = add_or_invite(admin, site.id, email)

      # The address registers and confirms on its own before accepting.
      user(:viewer, %{email: email})

      assert {:ok, %{outcome: :added}} = add_or_invite(admin, site.id, email)
      assert Accounts.list_invitations_for_org!(site.id, actor: admin) == []
      assert Invitations.peek(invitation.__metadata__.token) == nil
    end

    test "the role grant is audited in the site's own log" do
      admin = user(:admin)
      colleague = user(:viewer)
      site = org("audit")

      {:ok, %{outcome: :added}} = add_or_invite(admin, site.id, to_string(colleague.email))

      types =
        KilnCMS.Security.list_events!(actor: admin, tenant: site.id, page: [limit: 50])
        |> Map.get(:results)
        |> Enum.map(& &1.type)

      assert :role_granted in types
      refute :member_invited in types
    end
  end

  describe "an existing member" do
    test "is refused, and nothing is mailed" do
      admin = user(:admin)
      colleague = user(:viewer)
      site = org("member")
      {:ok, %{outcome: :added}} = add_or_invite(admin, site.id, to_string(colleague.email))
      drain_oban()
      assert_email_sent(fn _ -> true end)

      assert {:error, error} = add_or_invite(admin, site.id, to_string(colleague.email))
      assert InvitationRefused.in?(error, :already_member)
      drain_oban()
      refute_email_sent()
    end
  end

  describe "an address with no account" do
    test "is invited, and the invitation is audited in the site's log" do
      admin = user(:admin)
      email = address()
      site = org("invited")

      assert {:ok, %{outcome: :invited, invitation: invitation}} =
               add_or_invite(admin, site.id, email, %{role: :editor})

      assert invitation.role == :editor
      assert to_string(invitation.email) == email
      assert [_] = Accounts.list_invitations_for_org!(site.id, actor: admin)

      types =
        KilnCMS.Security.list_events!(actor: admin, tenant: site.id, page: [limit: 50])
        |> Map.get(:results)
        |> Enum.map(& &1.type)

      assert :member_invited in types

      # Not in the log of the site the admin happened to be on.
      refute KilnCMS.Security.list_events!(
               actor: admin,
               tenant: default_org(),
               page: [limit: 200]
             )
             |> Map.get(:results)
             |> Enum.any?(&(&1.target_id == invitation.id))
    end

    test "a live invitation already pending is refused" do
      admin = user(:admin)
      email = address()
      {:ok, %{outcome: :invited}} = add_or_invite(admin, default_org(), email)

      assert {:error, error} = add_or_invite(admin, default_org(), email)
      assert InvitationRefused.in?(error, :already_invited)
    end

    test "an expired invitation is sent again with a new token and the tier chosen now" do
      admin = user(:admin)
      email = address()

      {:ok, %{outcome: :invited, invitation: invitation}} =
        add_or_invite(admin, default_org(), email, %{role: :viewer})

      old = invitation.__metadata__.token

      Ash.Seed.update!(invitation, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :day)})

      assert {:ok, %{outcome: :reinvited, invitation: resent}} =
               add_or_invite(admin, default_org(), email, %{role: :editor})

      assert resent.id == invitation.id
      assert resent.role == :editor
      assert Invitations.peek(old) == nil
      assert Invitations.peek(resent.__metadata__.token).id == invitation.id
    end
  end

  describe "an address with an unconfirmed account" do
    test "is invited, not added — anyone could have registered it" do
      admin = user(:admin)
      squatter = user(:viewer, %{confirmed_at: nil})
      site = org("unconfirmed")

      assert {:ok, %{outcome: :invited}} =
               add_or_invite(admin, site.id, to_string(squatter.email))

      assert Accounts.list_memberships_for_user!(squatter.id, authorize?: false) == []
    end
  end

  describe "authorization" do
    test "an editor is refused and nothing is written" do
      editor = user(:editor)
      colleague = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               add_or_invite(editor, default_org(), to_string(colleague.email))

      assert Accounts.list_memberships_for_user!(colleague.id, authorize?: false) == []
    end

    test "a temporary platform admin can neither add nor invite" do
      temp =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      colleague = user(:viewer)
      site = org("temp")

      assert {:error, %Ash.Error.Invalid{}} =
               add_or_invite(temp, site.id, to_string(colleague.email))

      assert {:error, %Ash.Error.Invalid{}} = add_or_invite(temp, site.id, address())
    end
  end
end
