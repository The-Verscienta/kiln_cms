defmodule KilnCMS.Accounts.AdminAccountActionsTest do
  @moduledoc """
  The operator levers behind `/editor/accounts`: sending a named account a
  password-reset link, and the guard that stops an admin removing the last admin.

  Not `async: true`: the admin-reset path deliberately bypasses the per-address
  mail budget, and `KilnCMS.Accounts.AccountThrottle`'s counters are one
  node-wide ETS table — a concurrent test spending that budget would make
  "bypassed" indistinguishable from "allowed anyway".
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

    # The per-address budget exists because anyone can name any address on the
    # public form. An admin has already proved who they are, and a silent drop
    # here would make the console's confirmation a lie.
    test "the per-address mail budget does not silence it" do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])
      Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(previous, :mail_budget, 1))
      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)

      admin = user(:admin)
      subject = user(:editor)
      address = to_string(subject.email)
      on_exit(fn -> AccountThrottle.reset(address) end)

      # Spend the whole budget (one), so the public path would now drop the mail.
      assert AccountThrottle.allow_mail?(:password_reset, address)
      refute AccountThrottle.allow_mail?(:password_reset, address)

      assert {:ok, :sent} = Accounts.send_user_password_reset(subject.id, actor: admin)
      drain_oban()

      assert_email_sent(fn mail -> assert {_name, ^address} = hd(mail.to) end)
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
