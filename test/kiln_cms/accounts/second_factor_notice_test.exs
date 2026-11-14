defmodule KilnCMS.Accounts.SecondFactorNoticeTest do
  @moduledoc """
  The owner email on every second factor added (#2247, decision 1a), and the
  passkey cap and registration budget that keep "every" from becoming a flood
  (`KilnCMS.Accounts.SecondFactorNotice`, `Changes.NotifyFactorAdded`,
  `Validations.PasskeyCap`, `Changes.ThrottlePasskeyRegistration`).

  Mail is read off the queued delivery jobs rather than a drained mailbox, so
  "one per factor" is a count of what was queued.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import KilnCMS.PasskeyFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.PasskeyLimitReached
  alias KilnCMS.Accounts.Errors.PasskeyRegistrationThrottled
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker
  alias KilnCMS.Repo
  alias KilnCMS.TwoFactorFixtures

  @subject "A second factor was added to your"

  defp mails_to(user) do
    address = to_string(user.email)

    for %{args: %{"to" => [_name, ^address]} = args} <- all_enqueued(worker: DeliveryWorker),
        {:ok, mail} = Mail.open_args(args),
        String.starts_with?(mail.subject, @subject),
        do: mail
  end

  defp code(secret), do: TwoFactorFixtures.current_code(secret)

  defp enroll_totp(user) do
    {:ok, user} = Accounts.setup_totp(user, %{}, actor: user)

    {:ok, user} =
      Accounts.confirm_totp(user, %{code: code(user.totp_pending_secret)}, actor: user)

    user
  end

  # A request from Firefox on macOS, as the settings page passes it.
  defp firefox_context do
    %{
      KilnCMS.Security.Recorder.context_key() => %{
        ip: "203.0.113.9",
        user_agent:
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:126.0) Gecko/20100101 Firefox/126.0"
      }
    }
  end

  describe "an authenticator app" do
    test "a first enrollment mails the owner once" do
      user = passkey_user()
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

      {:ok, confirmed} =
        Accounts.confirm_totp(staged, %{code: code(staged.totp_pending_secret)},
          actor: staged,
          context: firefox_context()
        )

      assert [mail] = mails_to(user)
      assert mail.subject =~ @subject
      assert mail.html_body =~ "An authenticator app was set up"
      assert mail.html_body =~ "Firefox on macOS"
      assert mail.html_body =~ "Reset your password"
      assert mail.html_body =~ "signs out every session"
      assert mail.html_body =~ "administrator"

      # Nothing that would hand the factor to whoever reads the mail.
      secret = staged.totp_pending_secret
      codes = Ash.Resource.get_metadata(confirmed, :recovery_codes)
      assert is_list(codes) and codes != []

      for leak <- [Totp.base32_encode(secret), Base.encode64(secret), "203.0.113.9" | codes] do
        refute mail.html_body =~ leak
      end
    end

    test "a replacement mails the owner, saying it replaced the old one" do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

      {:ok, _} =
        Accounts.confirm_totp(
          staged,
          %{code: code(staged.totp_pending_secret), current_code: code(secret)},
          actor: staged
        )

      assert [mail] = mails_to(user)
      assert mail.html_body =~ "A new authenticator app replaced"
    end

    # The settings page confirms on its `current_user` assign, which predates
    # an enrollment another tab finished since: the wording comes from the
    # row, not from that struct.
    test "a confirmation on a struct loaded before another enrollment says it replaced one" do
      stale = passkey_user()
      enrolled_elsewhere = enroll_totp(stale)
      assert [_first] = mails_to(stale)
      assert is_nil(stale.totp_confirmed_at)

      {:ok, staged} = Accounts.setup_totp(stale, %{}, actor: stale)
      assert is_nil(staged.totp_confirmed_at)

      {:ok, _} =
        Accounts.confirm_totp(
          staged,
          %{
            code: code(staged.totp_pending_secret),
            current_code: code(enrolled_elsewhere.totp_secret)
          },
          actor: staged
        )

      mails = mails_to(stale)
      assert length(mails) == 2
      assert Enum.count(mails, &(&1.html_body =~ "A new authenticator app replaced")) == 1
      assert Enum.count(mails, &(&1.html_body =~ "An authenticator app was set up")) == 1
    end

    test "a wrong code mails nobody" do
      user = passkey_user()
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

      assert {:error, _} = Accounts.confirm_totp(staged, %{code: "000000"}, actor: staged)
      assert mails_to(user) == []
    end

    test "regenerating recovery codes mails nobody" do
      user = enroll_totp(passkey_user())
      assert [_enrollment] = mails_to(user)

      {:ok, _} =
        Accounts.regenerate_totp_recovery_codes(user, %{code: code(user.totp_secret)},
          actor: user
        )

      assert [_still_only_the_enrollment] = mails_to(user)
    end

    # The placement, pinned where it shows: the mail job is queued once the
    # enrollment's transaction is over, never inside it, where a later rollback
    # would leave the owner told about a factor that does not exist.
    test "the mail is queued after the commit, not inside the transaction" do
      test = self()
      handler = "second-factor-notice-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:oban, :engine, :insert_job, :start],
        # The handler is VM-wide and this module is async: only this test's
        # own inserts, which run in its process, count.
        fn _event, _measurements, _meta, _config ->
          if self() == test, do: send(test, {:mail_queued, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      enroll_totp(passkey_user())

      assert_received {:mail_queued, false}
      refute_received {:mail_queued, true}
    end
  end

  describe "a passkey" do
    test "each one added mails the owner once, naming no credential" do
      user = passkey_user()

      {:ok, first} = enroll(user, "cred-notice-1", "Laptop <b>Touch ID</b>")
      {:ok, _second} = enroll(user, "cred-notice-2", "Phone")

      assert [mail, _other] = mails_to(user)
      assert mail.html_body =~ "A passkey was added"

      for leak <- [first.credential_id, b64("cred-notice-1"), "Touch ID", "Phone"] do
        refute mail.html_body =~ leak
      end
    end

    test "an erased account is mailed nothing" do
      user =
        Ash.Seed.seed!(User, %{
          email: "erased-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          anonymized_at: DateTime.utc_now(),
          role: :editor
        })

      assert {:ok, _passkey} = enroll(user, "cred-erased")
      assert mails_to(user) == []
    end

    test "a mail that cannot be queued leaves the passkey in place, logged" do
      # A stored address the mailer refuses (`Mail.enqueue!/1` raises on it).
      user =
        Ash.Seed.seed!(User, %{
          email: "not an address #{System.unique_integer([:positive])}",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      log =
        capture_log(fn ->
          assert {:ok, _passkey} = enroll(user, "cred-notice-unmailable")
        end)

      assert [%{name: "Test key"}] = WebAuthn.list(user)
      assert log =~ "Second-factor notice for user #{user.id} not sent"
    end
  end

  describe "the passkey cap" do
    defp seed_passkeys(user, count) do
      for n <- 1..count//1 do
        Ash.Seed.seed!(Passkey, %{
          user_id: user.id,
          name: "Seeded #{n}",
          credential_id: b64("seeded-#{user.id}-#{n}"),
          public_key: :erlang.term_to_binary(%{stub: :cose_key})
        })
      end
    end

    test "is twenty" do
      assert Passkey.max_per_account() == 20
    end

    test "the twentieth is accepted and the twenty-first refused, and mailed nobody" do
      user = passkey_user()
      seed_passkeys(user, 19)

      assert {:ok, _} = enroll(user, "cred-twentieth")
      assert [_one] = mails_to(user)

      assert {:error, %{errors: errors}} = enroll(user, "cred-twenty-first")
      assert Enum.any?(errors, &match?(%PasskeyLimitReached{max: 20}, &1))

      assert length(WebAuthn.list(user)) == 20
      assert [_still_one] = mails_to(user)
    end
  end

  describe "the registration budget" do
    test "registrations over the hourly budget are refused, and mailed nobody" do
      user = passkey_user()
      budget = AccountThrottle.defaults()[:passkey_registration_budget]
      on_exit(fn -> AccountThrottle.forget_passkey_registrations(user.id) end)

      for n <- 1..budget, do: assert({:ok, _} = enroll(user, "cred-budget-#{n}"))

      assert {:error, %{errors: errors}} = enroll(user, "cred-budget-over")

      assert %PasskeyRegistrationThrottled{retry_after_seconds: seconds} =
               Enum.find(errors, &match?(%PasskeyRegistrationThrottled{}, &1))

      assert seconds > 0
      assert length(WebAuthn.list(user)) == budget
      assert length(mails_to(user)) == budget
    end

    test "is per account" do
      user = passkey_user()
      other = passkey_user()
      budget = AccountThrottle.defaults()[:passkey_registration_budget]

      on_exit(fn ->
        AccountThrottle.forget_passkey_registrations(user.id)
        AccountThrottle.forget_passkey_registrations(other.id)
      end)

      for n <- 1..budget, do: {:ok, _} = enroll(user, "cred-mine-#{n}")

      assert {:ok, _} = enroll(other, "cred-theirs")
    end
  end
end

defmodule KilnCMS.Accounts.SecondFactorNoticeRelayTest do
  @moduledoc """
  Which relay the added-factor notice goes through when the deployment has no
  outgoing mail server: the instance relay is gone, so a site that requires
  the account's factor and has a relay of its own carries it. That is the
  setup in which the enrollment's email proof may be skipped, so the notice is
  the owner's only word of a factor someone else added.

  `async: false`: it changes the mailer with `Application.put_env`.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SecondFactorNotice
  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker

  @moduletag :capture_log

  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  # A site that requires everyone to hold a second factor, and a viewer of it
  # with none, long past the deadline.
  setup do
    site = org("sfn-relay")

    Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
      org_id: site.id,
      required_for: :everyone,
      grace_days: 0,
      admin_required_since: @long_ago,
      editor_required_since: @long_ago,
      viewer_required_since: @long_ago,
      policy_changed_at: @long_ago
    })

    KilnCMS.Cache.bust_second_factor_policy(site.id)

    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "sfn-relay-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer,
        inserted_at: @long_ago
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :viewer,
      inserted_at: @long_ago
    })

    %{site: site, user: user}
  end

  defp put_env(app, key, value) do
    previous = Application.get_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(app, key),
        else: Application.put_env(app, key, previous)
    end)
  end

  defp no_operator_mailer! do
    put_env(:kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Local)
    put_env(:swoosh, :local, false)
    refute Mail.relay_available?(nil)
  end

  defp site_relay!(site) do
    KilnCMS.CMS.save_site_mail_relay!(
      %{
        host: "smtp.example.com",
        port: 587,
        username: "apikey",
        password: "s3cret-pass",
        from_email: "news@site.example"
      },
      tenant: site,
      authorize?: false
    )
  end

  defp notice_jobs(user) do
    address = to_string(user.email)

    for %{args: %{"to" => [_name, ^address]} = args} <- all_enqueued(worker: DeliveryWorker),
        do: args
  end

  test "with the instance relay, the notice goes through it", %{site: site, user: user} do
    site_relay!(site)
    assert Mail.relay_available?(nil)

    :ok = SecondFactorNotice.factor_added(user.id, :passkey, %{})

    assert [args] = notice_jobs(user)
    refute Map.get(args, "org_id")
  end

  test "with no instance relay, a requiring site's own relay carries it", %{
    site: site,
    user: user
  } do
    no_operator_mailer!()
    site_relay!(site)

    :ok = SecondFactorNotice.factor_added(user.id, :passkey, %{})

    assert [args] = notice_jobs(user)
    assert args["org_id"] == site.id
  end

  test "with no relay anywhere, it is queued as account mail as before", %{user: user} do
    no_operator_mailer!()

    :ok = SecondFactorNotice.factor_added(user.id, :passkey, %{})

    assert [args] = notice_jobs(user)
    refute Map.get(args, "org_id")
  end
end
