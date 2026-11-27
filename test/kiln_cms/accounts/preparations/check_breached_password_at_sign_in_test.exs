defmodule KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignInTest do
  @moduledoc """
  The breached-password check at an administrator's sign-in (#2407), at the
  action every password door runs (`:sign_in_with_password`): who is checked,
  which policy decides, what a refusal and a warning leave behind, and every
  way it must not call out or must fail open.

  The doors (sign-in form, direct POST, API) are
  `KilnCMSWeb.SignInBreachedPasswordTest`.

  `async: false`: the breach stub, the check's switch, the throttle budgets
  and the notice store are node-wide.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.BreachedPasswordFixtures
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  require Ash.Query

  alias AshAuthentication.Errors.AuthenticationFailed
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Accounts.Errors.PasswordResetRequired
  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMS.Accounts.User
  alias KilnCMS.Challenge
  alias KilnCMS.CMS
  alias KilnCMS.OrgSettings
  alias KilnCMS.Security.Event
  alias KilnCMSWeb.RateLimit

  @event [:kiln_cms, :password, :breach_check]

  setup do
    Cachex.clear(PasswordNotice.cache())
    %{a: org("bp-sign-in-a"), b: org("bp-sign-in-b")}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp unique_ip, do: "198.18.#{rem(uniq(), 250)}.#{rem(div(uniq(), 250), 250) + 1}"

  defp user(role, password, extra \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "bp-sign-in-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  defp member!(org, user, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
  end

  # A viewer globally whose `role` comes from a membership of `org`.
  defp member_of(org, role, password), do: member!(org, user(:viewer, password), role)

  defp save!(org, policy, check_on_sign_in) do
    CMS.save_site_password_policy!(
      %{breached_password_policy: policy, check_on_sign_in: check_on_sign_in},
      authorize?: false,
      tenant: org
    )
  end

  # What a door hands the action: the request, the org it resolved to, and
  # the surface.
  defp context(org, opts) do
    %{
      security_request: %{ip: Keyword.get(opts, :ip, unique_ip()), user_agent: "bp-test"},
      security_tenant: org_id(org)
    }
    |> Map.merge(Challenge.context(Keyword.get(opts, :surface, :browser)))
    |> Map.merge(Keyword.get(opts, :extra, %{}))
  end

  defp org_id(nil), do: Accounts.default_org_id()
  defp org_id(%{id: id}), do: id

  defp sign_in(user, password, opts) do
    email = if is_binary(user), do: user, else: to_string(user.email)

    AshAuthentication.Strategy.action(
      AshAuthentication.Info.strategy!(User, :password),
      :sign_in,
      %{"email" => email, "password" => password},
      context: context(Keyword.get(opts, :org), opts)
    )
  end

  defp breached(pw), do: enable!(&ok(&1, breached_body(pw, 42)))

  defp telemetry! do
    test = self()
    handler = "bp-sign-in-#{uniq()}"

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, _config ->
        send(test, {:breach_check, measurements, metadata, KilnCMS.Repo.in_transaction?()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp events(org, reason) do
    Event
    |> Ash.read!(authorize?: false, tenant: org_id(org))
    |> Enum.filter(&(&1.type == :sign_in_failed and &1.metadata["reason"] == reason))
  end

  defp reset_required?(error), do: PasswordResetRequired.find(error) != nil

  describe "off unless a site asks for it" do
    test "no row, or a row with the switch off, never looks the password up", %{a: a} do
      pw = password()
      breached(pw)
      admin = member_of(a, :admin, pw)

      assert {:ok, _user} = sign_in(admin, pw, org: a)

      save!(a, :block, false)
      assert {:ok, user} = sign_in(admin, pw, org: a)

      refute_received {:hibp_request, _, _}
      refute Map.has_key?(user.__metadata__, :password_breach)
    end

    test "the deployment switch off beats a site's switch on", %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      admin = member_of(a, :admin, pw)

      Application.put_env(
        :kiln_cms,
        BreachedPassword,
        Keyword.put(Application.get_env(:kiln_cms, BreachedPassword), :enabled, false)
      )

      assert PasswordPolicy.sign_in(admin) == :skip
      assert {:ok, _user} = sign_in(admin, pw, org: a)
      refute_received {:hibp_request, _, _}
    end
  end

  describe "breached, under :block" do
    setup %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      admin = member_of(a, :admin, pw)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)
      %{pw: pw, admin: admin}
    end

    test "refuses with PasswordResetRequired, not a wrong-password error", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      assert {:error, error} = sign_in(admin, pw, org: a)
      assert reset_required?(error)
      assert_received {:hibp_request, "/range/" <> _prefix, _headers}

      # It names nothing.
      message = Exception.message(PasswordResetRequired.find(error))
      for secret <- [to_string(admin.email), admin.id, a.id], do: refute(message =~ secret)
    end

    test "revokes the token the password minted and mints no remember-me token", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      assert {:error, _error} =
               AshAuthentication.Strategy.action(
                 AshAuthentication.Info.strategy!(User, :password),
                 :sign_in,
                 %{"email" => to_string(admin.email), "password" => pw, "remember_me" => "true"},
                 context: context(a, [])
               )

      # The minted token is now a revocation; the only other row is the
      # reset token the mail carries. No session token, no remember-me token.
      {:ok, tokens} =
        Accounts.Token
        |> Ash.Query.filter(subject == ^"user?id=#{admin.id}")
        |> Ash.read(authorize?: false)

      assert [_revoked] = Enum.filter(tokens, &(&1.purpose == "revocation"))

      assert tokens
             |> Enum.reject(&(&1.purpose == "revocation"))
             |> Enum.all?(&(&1.extra_data == %{"act" => "reset_password_with_token"}))

      refute Enum.any?(tokens, &(&1.purpose == "remember_me"))
    end

    test "mails a reset link that says why, within the reset-mail budget", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      address = to_string(admin.email)
      tighten_throttle!(mail_budget: 5)
      on_exit(fn -> AccountThrottle.reset(address) end)

      assert {:error, _error} = sign_in(admin, pw, org: a)
      drain_oban()

      assert_email_sent(fn mail ->
        assert {_name, ^address} = hd(mail.to)
        assert mail.subject =~ "Choose a new password"
        assert mail.html_body =~ "/password-reset/"
        assert mail.html_body =~ "known data breach"
        assert mail.html_body =~ "If that sign-in wasn't you"
        # Not the "you asked for this" reset mail.
        refute mail.html_body =~ "Click this link to reset your password"
        true
      end)

      # It charged the shared reset-mail budget: what is left is one less.
      used = for _ <- 1..10, AccountThrottle.allow_mail?(:password_reset, address), do: :ok
      assert length(used) == 4
    end

    test "a spent reset-mail budget sends nothing, and the refusal stands", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      address = to_string(admin.email)
      tighten_throttle!(mail_budget: 5)
      on_exit(fn -> AccountThrottle.reset(address) end)
      for _ <- 1..5, do: AccountThrottle.allow_mail?(:password_reset, address)

      assert {:error, error} = sign_in(admin, pw, org: a)
      assert reset_required?(error)
      drain_oban()
      refute_email_sent()
    end

    test "the per-account counter is not forgiven: the owner ends up paused", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      tighten_throttle!(budget: 3)

      for _ <- 1..3 do
        assert {:error, error} = sign_in(admin, pw, org: a)
        assert reset_required?(error)
      end

      # Paused now, and a paused attempt never reaches the lookup.
      flush_requests()
      assert {:error, %AuthenticationFailed{} = error} = sign_in(admin, pw, org: a)
      refute reset_required?(error)
      refute_received {:hibp_request, _, _}
    end

    test "is recorded in the deciding org, unsampled, and not in the request's", %{
      a: a,
      b: b,
      pw: pw,
      admin: admin
    } do
      member!(b, admin, :viewer)
      ip = unique_ip()

      # More than the per-address sample of a failed sign-in (five).
      for _ <- 1..7, do: assert({:error, _} = sign_in(admin, pw, org: b, ip: ip))

      recorded = events(a, "breached_password")
      assert length(recorded) == 7
      assert Enum.all?(recorded, &(&1.actor_id == admin.id and &1.ip == ip))

      assert Enum.all?(
               recorded,
               &(&1.metadata == %{"method" => "password", "reason" => "breached_password"})
             )

      assert events(b, "breached_password") == []
      # Not charged as guessing either: no "invalid credentials" anywhere.
      assert events(a, "invalid_credentials") == []
      assert events(b, "invalid_credentials") == []
    end
  end

  describe "the reset mail's branding (#3436)" do
    setup do
      tighten_throttle!(mail_budget: 50)
      :ok
    end

    defp brand!(org, name) do
      CMS.save_site_branding!(%{site_name: name}, authorize?: false, tenant: org.id)
      KilnCMS.Cache.bust_branding(org.id)
      on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
      org
    end

    # The subject of the one reset mail the refused sign-in queued.
    defp refused_mail_subject(person, pw, org) do
      assert {:error, error} = sign_in(person, pw, org: org)
      assert reset_required?(error)
      drain_oban()

      assert_email_sent(fn mail ->
        send(self(), {:reset_mail, mail.subject, mail.html_body})
        true
      end)

      assert_received {:reset_mail, subject, body}
      refute_email_sent()
      {subject, body}
    end

    test "names the site whose policy refused it, not the host's", %{a: a, b: b} do
      pw = password()
      breached(pw)
      brand!(a, "Alpha Press")
      brand!(b, "Beta Works")
      save!(a, :block, true)
      admin = member_of(a, :admin, pw)
      member!(b, admin, :viewer)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      {subject, body} = refused_mail_subject(admin, pw, b)
      assert subject == "Choose a new password for your Alpha Press account"
      assert body =~ "Alpha Press"
      refute subject =~ "Beta Works"
      refute body =~ "Beta Works"
    end

    test "the host's site when it is one of the deciding sites", %{a: a, b: b} do
      pw = password()
      breached(pw)
      brand!(a, "Alpha Press")
      brand!(b, "Beta Works")
      save!(a, :block, true)
      save!(b, :block, true)
      admin = member_of(a, :admin, pw)
      member!(b, admin, :admin)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      assert {"Choose a new password for your Beta Works account", _body} =
               refused_mail_subject(admin, pw, b)

      assert {"Choose a new password for your Alpha Press account", _body} =
               refused_mail_subject(admin, pw, a)
    end

    test "on an unrelated host, the deciding site with the smallest id, every time" do
      pw = password()
      breached(pw)
      one = brand!(org("bp-brand-one"), "Site One")
      two = brand!(org("bp-brand-two"), "Site Two")
      host = brand!(org("bp-brand-host"), "Host Site")
      save!(one, :block, true)
      save!(two, :block, true)
      admin = member_of(one, :admin, pw)
      member!(two, admin, :admin)
      member!(host, admin, :viewer)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      expected = if one.id < two.id, do: "Site One", else: "Site Two"

      for _ <- 1..3 do
        {subject, _body} = refused_mail_subject(admin, pw, host)
        assert subject == "Choose a new password for your #{expected} account"
      end
    end

    test "a platform admin's mail names the host's site, never a deciding one", %{a: a, b: b} do
      pw = password()
      breached(pw)
      brand!(a, "Alpha Press")
      brand!(b, "Beta Works")
      save!(b, :block, true)
      admin = user(:admin, pw)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      assert {"Choose a new password for your Alpha Press account", _body} =
               refused_mail_subject(admin, pw, a)

      # The same when the deciding sites cannot be read.
      PasswordPolicy.with_deciding_reader(fn _policy -> raise "boom" end, fn ->
        assert {"Choose a new password for your Alpha Press account", _body} =
                 refused_mail_subject(admin, pw, a)
      end)
    end

    test "the site name is escaped in the body", %{a: a, b: b} do
      pw = password()
      breached(pw)
      brand!(a, "<b>Alpha</b> & Co")
      save!(a, :block, true)
      admin = member_of(a, :admin, pw)
      member!(b, admin, :viewer)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      {_subject, body} = refused_mail_subject(admin, pw, b)
      assert body =~ "&lt;b&gt;Alpha&lt;/b&gt; &amp; Co"
      refute body =~ "<b>Alpha</b>"
    end
  end

  describe "breached, under :warn" do
    setup %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :warn, true)
      %{pw: pw, admin: member_of(a, :admin, pw)}
    end

    test "signs in, with the warning on the record and a note for the browser", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      assert {:ok, user} = sign_in(admin, pw, org: a)
      assert user.__metadata__.password_breach == %{status: :breached}
      assert is_binary(user.__metadata__.token)
      assert PasswordNotice.take(admin.id) == :sign_in
    end

    test "the API surface gets the metadata and no note", %{a: a, pw: pw, admin: admin} do
      assert {:ok, user} = sign_in(admin, pw, org: a, surface: :api)
      assert user.__metadata__.password_breach == %{status: :breached}
      refute PasswordNotice.take(admin.id)
    end
  end

  test "a clean password is looked up once and signs in with nothing to show", %{a: a} do
    pw = password()
    enable!(&ok(&1, clean_body(pw)))
    save!(a, :block, true)
    admin = member_of(a, :admin, pw)

    assert {:ok, user} = sign_in(admin, pw, org: a)
    assert_received {:hibp_request, _, _}
    refute_received {:hibp_request, _, _}
    refute Map.has_key?(user.__metadata__, :password_breach)
    refute PasswordNotice.take(admin.id)
  end

  test "an editor or a viewer of a site that checks is never looked up", %{a: a} do
    pw = password()
    breached(pw)
    save!(a, :block, true)

    for role <- [:editor, :viewer] do
      assert {:ok, _user} = sign_in(member_of(a, role, pw), pw, org: a)
    end

    assert {:ok, _user} = sign_in(user(:editor, pw), pw, org: a)
    refute_received {:hibp_request, _, _}
  end

  describe "across orgs" do
    test "an admin of a blocking site is refused on another site's host, whose switch is off",
         %{a: a, b: b} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      save!(b, :off, false)
      admin = member_of(a, :admin, pw)
      member!(b, admin, :editor)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      assert {:error, error} = sign_in(admin, pw, org: b)
      assert reset_required?(error)
    end

    test "only the admin orgs with the switch on decide: another's :block does not", %{
      a: a,
      b: b
    } do
      pw = password()
      breached(pw)
      save!(a, :warn, true)
      save!(b, :block, false)
      admin = member_of(a, :admin, pw)
      member!(b, admin, :admin)

      assert PasswordPolicy.sign_in(admin) == {:check, :warn}
      assert {:ok, user} = sign_in(admin, pw, org: b)
      assert user.__metadata__.password_breach == %{status: :breached}
    end

    test "a site's switch reaches its admins only, not another site's admins or its editors",
         %{a: a, b: b} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      save!(b, :off, false)

      # Admin of B only (switch off), editor of A (switch on).
      person = member_of(b, :admin, pw)
      member!(a, person, :editor)

      assert PasswordPolicy.sign_in(person) == :skip
      assert {:ok, _user} = sign_in(person, pw, org: a)
      refute_received {:hibp_request, _, _}
    end

    test "a site whose switch is on but whose policy is off checks nothing", %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :off, true)

      assert PasswordPolicy.sign_in(member_of(a, :admin, pw)) == :skip
    end

    test "a platform admin answers to every site with the switch on", %{a: a, b: b} do
      pw = password()
      breached(pw)
      save!(a, :warn, false)
      admin = user(:admin, pw)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      assert PasswordPolicy.sign_in(admin) == :skip

      save!(b, :block, true)
      assert PasswordPolicy.sign_in(admin) == {:check, :block}
      assert {:error, error} = sign_in(admin, pw, org: a)
      assert reset_required?(error)

      # Recorded in the deciding site only.
      assert [_event] = events(b, "breached_password")
      assert events(a, "breached_password") == []
    end

    for {name, reader} <- [
          {"fails", quote(do: fn _policy -> raise "boom" end)},
          {"finds none", quote(do: fn _policy -> [] end)}
        ] do
      test "a platform admin's deciding read that #{name} is audited in the request's site",
           %{a: a, b: b} do
        pw = password()
        breached(pw)
        save!(b, :block, true)
        admin = user(:admin, pw)
        on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

        log =
          capture_log(fn ->
            PasswordPolicy.with_deciding_reader(unquote(reader), fn ->
              assert {:error, error} = sign_in(admin, pw, org: a)
              assert reset_required?(error)
              assert PasswordResetRequired.find(error).org_ids == []
            end)
          end)

        # Once, in the request's site, unlabelled: a platform admin is not
        # one of its members. Nothing in the deciding site it could not read.
        assert [event] = events(a, "breached_password")
        assert event.actor_id == nil
        assert event.metadata == %{"method" => "password", "reason" => "breached_password"}
        assert events(b, "breached_password") == []
        assert events(a, "invalid_credentials") == []

        for secret <- [to_string(admin.email), admin.id, a.id, b.id],
            do: refute(log =~ secret)
      end
    end

    test "the request-site fallback is unsampled and labels a member platform admin",
         %{a: a, b: b} do
      pw = password()
      breached(pw)
      save!(b, :block, true)
      admin = member!(a, user(:admin, pw), :viewer)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)
      ip = unique_ip()

      PasswordPolicy.with_deciding_reader(fn _policy -> raise "boom" end, fn ->
        # More than the per-address sample of a failed sign-in (five).
        for _ <- 1..7, do: assert({:error, _} = sign_in(admin, pw, org: a, ip: ip))
      end)

      recorded = events(a, "breached_password")
      assert length(recorded) == 7
      assert Enum.all?(recorded, &(&1.actor_id == admin.id and &1.ip == ip))
      assert events(b, "breached_password") == []
      assert events(a, "invalid_credentials") == []
    end

    test "with no request site, a failed deciding read records nothing and still refuses",
         %{b: b} do
      pw = password()
      breached(pw)
      save!(b, :block, true)
      admin = user(:admin, pw)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      PasswordPolicy.with_deciding_reader(fn _policy -> raise "boom" end, fn ->
        assert {:error, error} =
                 AshAuthentication.Strategy.action(
                   AshAuthentication.Info.strategy!(User, :password),
                   :sign_in,
                   %{"email" => to_string(admin.email), "password" => pw},
                   context:
                     Map.merge(
                       %{security_request: %{ip: unique_ip(), user_agent: "bp-test"}},
                       Challenge.context(:browser)
                     )
                 )

        assert reset_required?(error)
      end)

      assert events(b, "breached_password") == []
      assert events(nil, "breached_password") == []
    end

    test "a pending admin membership, an expired grant and an erased account are not checked",
         %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :block, true)

      pending = user(:viewer, pw)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: a.id,
        user_id: pending.id,
        role: :admin,
        status: :pending
      })

      expired = user(:viewer, pw)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: a.id,
        user_id: expired.id,
        role: :viewer,
        granted_role: :admin,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), -3600)
      })

      erased = user(:admin, pw, %{anonymized_at: DateTime.utc_now()})

      for person <- [pending, expired, erased],
          do: assert(PasswordPolicy.sign_in(person) == :skip)
    end
  end

  describe "the decision is bounded" do
    defp queries(fun) do
      test = self()
      handler = "bp-sign-in-queries-#{uniq()}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test, do: send(test, :query)
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      count_queries(0)
    end

    defp count_queries(n) do
      receive do
        :query -> count_queries(n + 1)
      after
        0 -> n
      end
    end

    test "a member costs two queries whether they administer one site or six" do
      pw = password()
      breached(pw)
      one = user(:viewer, pw)
      six = user(:viewer, pw)

      for n <- 1..6 do
        site = org("bp-bound-#{n}")
        save!(site, :block, true)
        member!(site, six, :admin)
        if n == 1, do: member!(site, one, :admin)
      end

      assert PasswordPolicy.sign_in(one) == {:check, :block}
      assert queries(fn -> PasswordPolicy.sign_in(one) end) <= 2

      assert queries(fn -> PasswordPolicy.sign_in(six) end) ==
               queries(fn -> PasswordPolicy.sign_in(one) end)
    end

    test "a platform admin costs one query to decide, however many sites" do
      pw = password()
      breached(pw)
      for n <- 1..6, do: save!(org("bp-bound-all-#{n}"), :block, true)
      admin = user(:admin, pw)

      assert queries(fn -> assert PasswordPolicy.sign_in(admin) == {:check, :block} end) <= 1

      # The deciding sites are read only when asked for (the audit of a refusal).
      assert {:check, :block, deciding} = PasswordPolicy.sign_in_decision(admin)
      assert length(deciding.()) == 6
    end
  end

  describe "never for an attempt that did not pass the password" do
    setup %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      %{pw: pw, admin: member_of(a, :admin, pw)}
    end

    test "a wrong password or an unknown address is the usual refusal, with no lookup", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

      assert {:error, %AuthenticationFailed{} = wrong} = sign_in(admin, pw <> "x", org: a)
      refute reset_required?(wrong)

      assert {:error, %AuthenticationFailed{} = unknown} =
               sign_in("nobody-#{uniq()}@example.com", pw, org: a)

      refute reset_required?(unknown)
      refute_received {:hibp_request, _, _}
    end

    test "an account at its sign-in budget is refused before any lookup", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      address = to_string(admin.email)
      tighten_throttle!(budget: 3)
      on_exit(fn -> AccountThrottle.reset(address) end)
      for _ <- 1..3, do: AccountThrottle.consume(address)

      assert {:error, %AuthenticationFailed{}} = sign_in(admin, pw, org: a)
      refute_received {:hibp_request, _, _}
    end

    test "an address out of its :auth budget is refused before any lookup", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      KilnCMS.RateLimitHelpers.restore_limits_on_exit()
      {limit, _scale} = Map.fetch!(RateLimit.limits(), :auth)
      KilnCMS.RateLimitHelpers.put_limit(:auth, limit, :timer.hours(24 * 365 * 100))
      ip = unique_ip()
      assert RateLimit.check(:auth, ip, limit) == :allow

      assert {:error, %AuthenticationFailed{}} =
               sign_in(admin, pw, org: a, ip: ip, extra: ThrottleSignIn.client_ip_context(ip))

      refute_received {:hibp_request, _, _}
    end

    test "an attempt refused for want of a human-verification challenge is not looked up", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      KilnCMS.ChallengeFixtures.pin_windows!([:account, :ip])
      KilnCMS.ChallengeFixtures.enable!()
      address = to_string(admin.email)
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..Challenge.threshold(:account) do
        AccountThrottle.consume(address)
        AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))
      end

      assert {:error, error} = sign_in(admin, pw, org: a)
      assert ChallengeRequired.find(error)
      refute_received {:hibp_request, _, _}
    end
  end

  describe "failing open" do
    setup %{a: a} do
      pw = password()
      save!(a, :block, true)
      telemetry!()
      %{pw: pw, admin: member_of(a, :admin, pw)}
    end

    for {name, handler, reason} <- [
          {"a 500", quote(do: &Plug.Conn.send_resp(&1, 500, "")), :http_status},
          {"a malformed body", quote(do: &ok(&1, "<html>oops</html>")), :malformed}
        ] do
      test "#{name} signs in, counted as an error", %{a: a, pw: pw, admin: admin} do
        enable!(unquote(handler))

        log = capture_log(fn -> assert {:ok, _user} = sign_in(admin, pw, org: a) end)

        assert_received {:breach_check, _measurements,
                         %{result: :error, reason: unquote(reason), action: :sign_in}, _txn}

        assert log =~ "allowing the sign-in"
        for secret <- [to_string(admin.email), admin.id, pw], do: refute(log =~ secret)
      end
    end

    test "a lookup past the sign-in deadline signs in, counted as a timeout", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      enable!(
        fn conn ->
          Process.sleep(300)
          ok(conn, breached_body(pw, 9))
        end,
        sign_in_deadline: 50
      )

      started = System.monotonic_time(:millisecond)
      assert {:ok, user} = sign_in(admin, pw, org: a)
      assert System.monotonic_time(:millisecond) - started < 300

      refute Map.has_key?(user.__metadata__, :password_breach)
      assert_received {:breach_check, _, %{result: :error, reason: :timeout}, _txn}
    end

    test "an unreadable setting signs in with no lookup, and the log names nobody", %{
      a: a,
      pw: pw,
      admin: admin
    } do
      breached(pw)

      log =
        capture_log(fn ->
          OrgSettings.with_actor(nil, fn ->
            assert PasswordPolicy.sign_in(admin) == :skip
            assert {:ok, _user} = sign_in(admin, pw, org: a)
          end)
        end)

      refute_received {:hibp_request, _, _}

      # Other settings refused here log their own query, as they always have;
      # this check's line names nothing.
      line =
        log
        |> String.split("\n")
        |> Enum.find(
          &(&1 =~ "breached-password sign-in policy could not be resolved; not checking")
        )

      assert line
      for secret <- [to_string(admin.email), admin.id, a.id], do: refute(line =~ secret)
      refute log =~ to_string(admin.email)
    end
  end

  describe "telemetry" do
    test "one event per checked sign-in, outside any transaction, with exactly the usual keys",
         %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :warn, true)
      admin = member_of(a, :admin, pw)
      telemetry!()

      assert {:ok, _user} = sign_in(admin, pw, org: a)

      assert_received {:breach_check, measurements, metadata, in_transaction?}
      refute_received {:breach_check, _, _, _}

      refute in_transaction?
      assert %{count: 1, duration: duration} = measurements
      assert is_integer(duration)

      assert Map.keys(metadata) |> Enum.sort() ==
               [:action, :enforcement, :policy, :reason, :result]

      assert metadata == %{
               action: :sign_in,
               policy: :warn,
               enforcement: :warned,
               result: :breached,
               reason: nil
             }
    end

    test "a blocked sign-in is enforcement: :blocked; a skipped one emits nothing", %{a: a} do
      pw = password()
      breached(pw)
      save!(a, :block, true)
      admin = member_of(a, :admin, pw)
      on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)
      telemetry!()

      assert {:error, _} = sign_in(admin, pw, org: a)
      assert_received {:breach_check, _, %{enforcement: :blocked, policy: :block}, _}

      assert {:ok, _} = sign_in(member_of(a, :editor, pw), pw, org: a)
      refute_received {:breach_check, _, _, _}
    end
  end

  test "a two-factor administrator is refused at the password, before the code", %{a: a} do
    {admin, _secret} = KilnCMS.TwoFactorFixtures.enabled_user(role: :viewer)
    member!(a, admin, :admin)
    pw = KilnCMS.TwoFactorFixtures.password()
    breached(pw)
    save!(a, :block, true)
    on_exit(fn -> AccountThrottle.reset(to_string(admin.email)) end)

    assert {:error, error} = sign_in(admin, pw, org: a)
    assert reset_required?(error)
  end

  # The suite runs with budgets far above the real ones (`config/test.exs`):
  # put back the one under test, and a window wide enough not to roll over.
  defp tighten_throttle!(opts) do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous, [window: :timer.hours(1)] ++ opts)
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
  end

  defp flush_requests do
    receive do
      {:hibp_request, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
