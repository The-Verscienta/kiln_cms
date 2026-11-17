defmodule KilnCMS.Accounts.FactorRemovedNoticeTest do
  @moduledoc """
  A second factor removed tells the owner by email and the site's admins by a
  `two_factor_disabled` alert, whether the owner removed it or an
  administrator did (`KilnCMS.Accounts.SecondFactorNotice.factor_removed/4`,
  `Changes.NotifyFactorRemoved`, `KilnCMS.Security.Alerts`). A refused
  removal does neither.

  `async: false`: alerts are turned on (`KilnCMS.Test.SecurityAlerts.enable/0`,
  an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures
  import KilnCMS.PasskeyFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Repo
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @subject "A second factor was removed from your"

  setup do
    SecurityAlerts.enable()
    %{org: org("factor-removed-#{System.unique_integer([:positive])}")}
  end

  defp mails_to(user) do
    address = to_string(user.email)

    for %{args: %{"to" => [_name, ^address]} = args} <- all_enqueued(worker: DeliveryWorker),
        {:ok, mail} = Mail.open_args(args),
        String.starts_with?(mail.subject, @subject),
        do: mail
  end

  # A request from Firefox on macOS on `org`'s site, as the settings page
  # passes it.
  defp ctx(org) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header(
        "user-agent",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:126.0) Gecko/20100101 Firefox/126.0"
      )

    AuthEvents.context(conn, org.id)
  end

  # The site alerts claimed on `org`'s site.
  defp alert_kinds(org) do
    org_id = org.id
    for %{"kind" => kind, "org_id" => ^org_id} <- SecurityAlerts.dispatches(), do: kind
  end

  defp passkey_of(user, bytes) do
    {:ok, _} = enroll(user, bytes)
    [passkey] = Enum.filter(WebAuthn.list(user), &(&1.credential_id == b64(bytes)))
    passkey
  end

  # The enrollment mails are a different subject; start each test with none
  # of ours queued.
  defp fresh_passkey(user, bytes) do
    passkey = passkey_of(user, bytes)
    assert mails_to(user) == []
    passkey
  end

  describe "a passkey removed by its owner" do
    test "mails the owner and raises two_factor_disabled", %{org: org} do
      user = passkey_user()
      passkey = fresh_passkey(user, "cred-removed-self")

      assert :ok =
               Accounts.remove_passkey(passkey,
                 actor: user,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert [mail] = mails_to(user)
      assert mail.subject =~ @subject
      assert mail.html_body =~ "A passkey was removed"
      assert mail.html_body =~ "Firefox on macOS"
      assert mail.html_body =~ "Reset your password"
      refute mail.html_body =~ "removed by an administrator"
      # Not the name whoever registered it typed.
      refute mail.html_body =~ "Test key"

      assert "two_factor_disabled" in alert_kinds(org)
    end

    test "is queued after the commit, not inside the transaction" do
      user = passkey_user()
      passkey = fresh_passkey(user, "cred-removed-after-commit")
      test = self()
      handler = "factor-removed-notice-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:oban, :engine, :insert_job, :start],
        fn _event, _measurements, _meta, _config ->
          if self() == test, do: send(test, {:mail_queued, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok =
               Accounts.remove_passkey(passkey,
                 actor: user,
                 context: TwoFactorFixtures.verified_now()
               )

      assert_received {:mail_queued, false}
      refute_received {:mail_queued, true}
    end
  end

  describe "a passkey removed by a platform admin" do
    test "mails the owner, naming the admin, and raises two_factor_disabled", %{org: org} do
      owner = passkey_user()
      admin = passkey_user(:admin)
      passkey = fresh_passkey(owner, "cred-removed-admin")
      # The admin proves a second factor of their own (the step-up).
      _admins_own = passkey_of(admin, "cred-removed-admin-own")

      {:ok, passkey} = Accounts.get_passkey(passkey.id, actor: admin)

      assert :ok =
               Accounts.remove_passkey(passkey,
                 actor: admin,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert [mail] = mails_to(owner)
      assert mail.html_body =~ "A passkey was removed"
      # No display name: named as "an administrator", never by address (#3044).
      assert mail.html_body =~ "It was removed by an administrator."
      refute mail.html_body =~ to_string(admin.email)
      refute mail.subject =~ to_string(admin.email)
      assert mail.html_body =~ "ask an administrator of your site why"
      assert mails_to(admin) == []

      assert "two_factor_disabled" in alert_kinds(org)
    end

    test "names an admin with a display name by that name, escaped, and never by address",
         %{org: org} do
      owner = passkey_user()
      admin = passkey_user(:admin) |> Ash.Seed.update!(%{name: "Ada <b>L</b> & co"})
      passkey = fresh_passkey(owner, "cred-removed-named-admin")
      _admins_own = passkey_of(admin, "cred-removed-named-admin-own")

      {:ok, passkey} = Accounts.get_passkey(passkey.id, actor: admin)

      assert :ok =
               Accounts.remove_passkey(passkey,
                 actor: admin,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert [mail] = mails_to(owner)
      assert mail.html_body =~ "removed by an administrator, Ada &lt;b&gt;L&lt;/b&gt; &amp; co."
      refute mail.html_body =~ "<b>L</b>"
      refute mail.html_body =~ to_string(admin.email)
      refute mail.subject =~ to_string(admin.email)
    end

    test "an admin whose display name is blank is named generically", %{org: org} do
      owner = passkey_user()
      admin = passkey_user(:admin) |> Ash.Seed.update!(%{name: ""})
      passkey = fresh_passkey(owner, "cred-removed-blank-admin")
      _admins_own = passkey_of(admin, "cred-removed-blank-admin-own")

      {:ok, passkey} = Accounts.get_passkey(passkey.id, actor: admin)

      assert :ok =
               Accounts.remove_passkey(passkey,
                 actor: admin,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert [mail] = mails_to(owner)
      assert mail.html_body =~ "It was removed by an administrator."
      refute mail.html_body =~ to_string(admin.email)
    end
  end

  describe "a refused removal" do
    test "another member's passkey: no mail, no alert", %{org: org} do
      owner = passkey_user()
      stranger = passkey_user()
      passkey = fresh_passkey(owner, "cred-removed-refused")

      assert {:error, _} =
               Accounts.remove_passkey(passkey,
                 actor: stranger,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert [_still_there] = WebAuthn.list(owner)
      assert mails_to(owner) == []
      assert alert_kinds(org) == []
    end

    test "a wrong code turning the authenticator app off: no mail, no alert", %{org: org} do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)

      assert {:error, _} =
               Accounts.disable_totp(user, %{code: "000000"}, actor: user, context: ctx(org))

      assert mails_to(user) == []
      assert alert_kinds(org) == []
    end
  end

  describe "the authenticator app turned off" do
    test "mails the owner and raises two_factor_disabled", %{org: org} do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)

      assert {:ok, _} =
               Accounts.disable_totp(user, %{code: TwoFactorFixtures.current_code(secret)},
                 actor: user,
                 context: ctx(org)
               )

      assert [mail] = mails_to(user)
      assert mail.html_body =~ "The authenticator app was turned off"
      assert mail.html_body =~ "recovery codes no longer work"

      assert "two_factor_disabled" in alert_kinds(org)
    end
  end

  describe "no owner to tell" do
    test "erasing an account removes its passkeys and mails nobody" do
      user = passkey_user()
      _passkey = fresh_passkey(user, "cred-removed-erased")
      admin = passkey_user(:admin)

      {:ok, _} = Accounts.anonymize_user(user, actor: admin)

      assert WebAuthn.list(user) == []
      assert mails_to(user) == []
    end

    test "a mail that cannot be queued leaves the passkey removed, logged" do
      user =
        Ash.Seed.seed!(User, %{
          email: "not an address #{System.unique_integer([:positive])}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      {:ok, _} = enroll(user, "cred-removed-unmailable")
      [passkey] = WebAuthn.list(user)

      log =
        capture_log(fn ->
          assert :ok =
                   Accounts.remove_passkey(passkey,
                     actor: user,
                     context: TwoFactorFixtures.verified_now()
                   )
        end)

      assert WebAuthn.list(user) == []
      assert log =~ "Second-factor removal notice for user #{user.id} not sent"
    end
  end

  describe "the step-up before a passkey is removed" do
    test "no fresh second factor and no code: refused, nothing mailed or alerted", %{org: org} do
      user = passkey_user()
      passkey = fresh_passkey(user, "cred-step-up-none")

      assert {:error, error} = Accounts.remove_passkey(passkey, actor: user, context: ctx(org))
      assert Exception.message(error) =~ "sign in again with your passkey"

      assert [_still_there] = WebAuthn.list(user)
      assert mails_to(user) == []
      assert alert_kinds(org) == []
    end

    test "a mark older than 15 minutes does not count", %{org: org} do
      user = passkey_user()
      passkey = fresh_passkey(user, "cred-step-up-stale")
      stale = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

      assert {:error, _} =
               Accounts.remove_passkey(passkey,
                 actor: user,
                 context: Map.put(ctx(org), :second_factor_verified_at, stale)
               )

      assert [_still_there] = WebAuthn.list(user)
    end

    test "a current authenticator code removes it; a wrong one doesn't", %{org: org} do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      passkey = fresh_passkey(user, "cred-step-up-code")

      assert {:error, error} =
               Accounts.remove_passkey(passkey, %{code: "000000"}, actor: user, context: ctx(org))

      assert Exception.message(error) =~ "That code isn't valid"
      assert [_still_there] = WebAuthn.list(user)

      assert :ok =
               Accounts.remove_passkey(
                 passkey,
                 %{code: TwoFactorFixtures.current_code(secret)},
                 actor: user,
                 context: ctx(org)
               )

      assert WebAuthn.list(user) == []
      assert [_mail] = mails_to(user)
    end

    test "a platform admin with no second factor of their own is refused", %{org: org} do
      owner = passkey_user()
      admin = passkey_user(:admin)
      passkey = fresh_passkey(owner, "cred-step-up-admin")

      assert {:error, error} =
               Accounts.remove_passkey(passkey,
                 actor: admin,
                 context: TwoFactorFixtures.verified_now(ctx(org))
               )

      assert Exception.message(error) =~ "Set up two-step sign-in on your own account first"
      assert [_still_there] = WebAuthn.list(owner)
    end
  end
end
