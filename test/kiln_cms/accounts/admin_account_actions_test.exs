defmodule KilnCMS.Accounts.AdminAccountActionsTest do
  @moduledoc """
  The operator levers behind `/editor/accounts`: sending a named account a
  password-reset link, and the guard that stops an admin removing the last admin.

  Not `async: true`: these tests tighten `KilnCMS.Accounts.AccountThrottle`'s
  mail budget, whose counters are one node-wide ETS table.
  """
  use KilnCMS.DataCase, async: false

  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{AccountThrottle, User}

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "admin-actions-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  describe "send_password_reset" do
    test "mails a reset link and says so" do
      admin = user(:admin)
      subject = user(:editor)

      assert {:ok, :sent} = Accounts.send_user_password_reset(subject.id, actor: admin)
      drain_oban()

      address = to_string(subject.email)

      assert_email_sent(fn mail ->
        assert {_name, ^address} = hd(mail.to)
        assert mail.subject =~ "Reset"
        assert mail.html_body =~ "/password-reset/"
      end)
    end

    test "a non-admin cannot send one" do
      editor = user(:editor)
      subject = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.send_user_password_reset(subject.id, actor: editor)
    end

    test "an unknown id is named rather than silently ignored" do
      admin = user(:admin)

      assert {:error, error} =
               Accounts.send_user_password_reset(Ash.UUID.generate(), actor: admin)

      assert Exception.message(error) =~ "no account with that id"
    end

    # An erased account's password hash has no matching plaintext and its address
    # is `@deleted.invalid`, so a reset link would be mail to nowhere offering
    # credentials on an account that must never sign in again.
    test "an erased account is refused" do
      admin = user(:admin)
      subject = user(:viewer)
      {:ok, erased} = Accounts.anonymize_user(subject, actor: admin)

      assert {:error, error} = Accounts.send_user_password_reset(erased.id, actor: admin)
      assert Exception.message(error) =~ "erased"
    end

    # The budget bounds reset mail to one address per hour whoever asks — a
    # temporary admin included. The admin path charges it, once, and says so by
    # name when it is spent, instead of reporting "sent" for mail the sender drops.
    test "a spent per-address budget is refused by name, and nothing is sent" do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])
      Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(previous, :mail_budget, 1))
      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)

      admin = user(:admin)
      subject = user(:editor)
      address = to_string(subject.email)
      on_exit(fn -> AccountThrottle.reset(address) end)

      assert {:ok, :sent} = Accounts.send_user_password_reset(subject.id, actor: admin)
      drain_oban()
      assert_email_sent(fn mail -> assert {_name, ^address} = hd(mail.to) end)

      assert {:error, error} = Accounts.send_user_password_reset(subject.id, actor: admin)
      assert Exception.message(error) =~ "too many reset links"
      drain_oban()
      assert_no_email_sent()
    end

    # One admin reset spends one unit, not two (the action charges; the sender is
    # told it was charged) — and shares the budget with the owner's own requests.
    test "an admin reset spends exactly one unit of the shared budget" do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])
      Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(previous, :mail_budget, 2))
      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)

      admin = user(:admin)
      subject = user(:editor)
      address = to_string(subject.email)
      on_exit(fn -> AccountThrottle.reset(address) end)

      assert {:ok, :sent} = Accounts.send_user_password_reset(subject.id, actor: admin)
      # One unit left of two.
      assert AccountThrottle.allow_mail?(:password_reset, address)
      refute AccountThrottle.allow_mail?(:password_reset, address)
    end
  end

  describe "a temporary admin" do
    setup do
      standing = user(:admin)
      temp = user(:editor)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          temp,
          %{
            granted_role: :admin,
            granted_role_expires_at: DateTime.add(DateTime.utc_now(), 6, :hour)
          },
          actor: standing
        )

      # The session actor: loaded through a read, so the grant is folded in.
      actor = Accounts.get_user!(temp.id, authorize?: false)
      assert actor.role == :admin

      %{standing: standing, temp: temp, actor: actor}
    end

    test "cannot make itself a permanent admin", %{temp: temp, actor: actor} do
      target =
        Accounts.get_user!(temp.id, KilnCMS.Accounts.RoleGrant.unfolded() ++ [authorize?: false])

      assert {:error, error} = Accounts.manage_user_access(target, %{role: :admin}, actor: actor)
      assert Exception.message(error) =~ "standing admin"

      assert Accounts.get_user!(
               temp.id,
               KilnCMS.Accounts.RoleGrant.unfolded() ++ [authorize?: false]
             ).role ==
               :editor
    end

    test "cannot extend its own grant", %{temp: temp, actor: actor} do
      target =
        Accounts.get_user!(temp.id, KilnCMS.Accounts.RoleGrant.unfolded() ++ [authorize?: false])

      assert {:error, error} =
               Accounts.grant_user_temporary_role(
                 target,
                 %{
                   granted_role: :admin,
                   granted_role_expires_at: DateTime.add(DateTime.utc_now(), 365, :day)
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "standing admin"
    end

    test "cannot confer a site tier that would outlast the grant", %{actor: actor} do
      colleague = user(:viewer)

      assert {:error, error} =
               Accounts.create_org_membership(
                 %{
                   user_id: colleague.id,
                   organization_id: Accounts.default_org_id(),
                   role: :admin
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "standing admin"
    end

    # The grant is for ordinary admin work; only tier-granting is withheld.
    test "can still do ordinary admin work", %{actor: actor} do
      subject = user(:viewer)
      assert {:ok, :sent} = Accounts.send_user_password_reset(subject.id, actor: actor)
    end
  end

  describe "erasure and a live grant" do
    test "clears the grant, the site grants and the API keys" do
      admin = user(:admin)
      subject = user(:editor)
      in_6h = DateTime.add(DateTime.utc_now(), 6, :hour)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          subject,
          %{granted_role: :admin, granted_role_expires_at: in_6h},
          actor: admin
        )

      membership =
        Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
          user_id: subject.id,
          organization_id: Accounts.default_org_id(),
          role: :viewer
        })

      {:ok, _} =
        Accounts.grant_membership_temporary_role(
          membership,
          %{granted_role: :editor, granted_role_expires_at: in_6h},
          actor: admin
        )

      {:ok, key} =
        Accounts.mint_api_key(subject.id, "ci", DateTime.add(DateTime.utc_now(), 30, :day),
          actor: admin
        )

      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      erased =
        Accounts.get_user!(
          subject.id,
          KilnCMS.Accounts.RoleGrant.unfolded() ++ [authorize?: false]
        )

      assert is_nil(erased.granted_role)
      assert is_nil(erased.granted_role_expires_at)
      # And a fresh, folded read no longer presents it as an admin.
      assert Accounts.get_user!(subject.id, authorize?: false).role == :viewer

      refute subject.id in Enum.map(
               KilnCMS.Accounts.Scoping.users_with_tier(Accounts.default_org_id(), [:admin]),
               & &1.id
             )

      assert is_nil(
               Accounts.get_org_membership!(
                 subject.id,
                 Accounts.default_org_id(),
                 KilnCMS.Accounts.RoleGrant.unfolded() ++ [authorize?: false]
               ).granted_role
             )

      assert Accounts.get_api_key!(key.id, authorize?: false).revoked_at
    end
  end

  describe "the last admin" do
    test "cannot be demoted" do
      # `KilnCMS.DataCase` gives each test its own transaction, so this admin is
      # the only one the instance has for the duration.
      admin = user(:admin)

      assert {:error, error} =
               Accounts.manage_user_access(admin, %{role: :editor}, actor: admin)

      assert Exception.message(error) =~ "no admin"
      assert Accounts.get_user!(admin.id, authorize?: false).role == :admin
    end

    # A system call is not exempt merely for having no actor — `Beta.Round` seats
    # testers through `:manage_access` with `authorize?: false`.
    test "cannot be demoted by an actorless system call" do
      admin = user(:admin)

      assert {:error, error} =
               Accounts.manage_user_access(admin, %{role: :viewer}, authorize?: false)

      assert Exception.message(error) =~ "no admin"
    end

    # The one named exemption: a staging scrub erases every account on purpose.
    test "can be erased by the scrub's named exemption" do
      admin = user(:admin)

      assert {:ok, erased} =
               Accounts.anonymize_user(admin,
                 authorize?: false,
                 context: KilnCMS.Accounts.Validations.NotLastAdmin.exempt()
               )

      assert erased.anonymized_at
    end

    test "cannot be erased" do
      admin = user(:admin)

      assert {:error, error} = Accounts.anonymize_user(admin, actor: admin)
      assert Exception.message(error) =~ "no admin"
    end

    test "can be demoted once there is another" do
      admin = user(:admin)
      _second = user(:admin)

      assert {:ok, demoted} =
               Accounts.manage_user_access(admin, %{role: :editor}, actor: admin)

      assert demoted.role == :editor
    end

    # A grant expires, so an instance whose only admin holds a temporary one is
    # the lockout this guard exists to prevent, merely deferred.
    test "a temporary admin does not count as the other one" do
      admin = user(:admin)
      temp = user(:editor)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          temp,
          %{
            granted_role: :admin,
            granted_role_expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          },
          actor: admin
        )

      assert {:error, error} =
               Accounts.manage_user_access(admin, %{role: :editor}, actor: admin)

      assert Exception.message(error) =~ "no admin"
    end

    # Narrowing scopes or audiences is not a demotion, and must not be caught by
    # the guard — `:manage_access` carries all of those on one action.
    test "a non-role edit on the last admin is untouched" do
      admin = user(:admin)

      assert {:ok, updated} =
               Accounts.manage_user_access(admin, %{audiences: [:member]}, actor: admin)

      assert updated.role == :admin
      assert updated.audiences == [:member]
    end
  end
end
