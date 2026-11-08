defmodule KilnCMSWeb.SecurityAuthEventsTest do
  @moduledoc """
  The authentication family of the security audit log (#2241): sign-ins,
  refused sign-ins, lockouts, second factors, recovery codes and passkeys are
  recorded with the actor, org, client address and user agent, and a refusal is
  recorded without telling an unknown address from a known one.

  Every test works on an address of its own (the setup conn peers from one, the
  direct-action tests build one into the context), so events are told apart by
  address and the sample/lock buckets never collide.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.PasskeyFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Security.Event
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @password "password123456"
  @ua "Mozilla/5.0 AuthEventsTest"

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp seed_user(extra \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "auth-ev-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        extra
      )
    )
  end

  defp events do
    Event |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!(authorize?: false, tenant: org_id())
  end

  defp events(type, ip), do: Enum.filter(events(), &(&1.type == type and &1.ip == ip))
  defp events_for(user), do: Enum.filter(events(), &(&1.actor_id == user.id))

  defp ip_of(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp unique_ip do
    n = uniq()
    "198.51.#{rem(n, 250)}.#{rem(div(n, 250), 250) + 1}"
  end

  # The context a door hands the sign-in action (the plug / SignInLive / API).
  defp ctx(ip), do: ctx(ip, org_id())

  defp ctx(ip, org) do
    %{
      security_request: %{ip: ip, user_agent: @ua},
      security_tenant: org
    }
  end

  defp sign_in(email, password, context) do
    AshAuthentication.Strategy.action(
      AshAuthentication.Info.strategy!(User, :password),
      :sign_in,
      %{"email" => email, "password" => password},
      context: context
    )
  end

  defp post_sign_in(conn, body) do
    conn
    |> put_req_header("user-agent", @ua)
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", body)
  end

  describe "sign_in (headless)" do
    test "a completed password sign-in records who, where, from what and how", %{conn: conn} do
      user = seed_user()

      conn = post_sign_in(conn, %{"email" => to_string(user.email), "password" => @password})
      assert json_response(conn, 201)["token"]

      assert [event] = events(:sign_in, ip_of(conn))
      assert event.actor_id == user.id
      assert event.actor_label == to_string(user.email)
      assert event.ip == ip_of(conn)
      assert event.user_agent == @ua
      assert event.metadata == %{"method" => "password"}
      assert event.org_id == org_id()
    end

    test "the password step of a two-factor account is not a sign-in; the code is", %{conn: conn} do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      ip = ip_of(conn)

      first =
        post_sign_in(conn, %{
          "email" => to_string(user.email),
          "password" => TwoFactorFixtures.password()
        })

      assert %{"pending_token" => pending} = json_response(first, 200)
      assert events(:sign_in, ip) == []

      second =
        build_conn()
        |> Map.put(:remote_ip, conn.remote_ip)
        |> put_req_header("user-agent", @ua)
        |> put_req_header("content-type", "application/json")
        |> post("/api/auth/sign_in/verify", %{
          "pending_token" => pending,
          "code" => TwoFactorFixtures.current_code(secret)
        })

      assert json_response(second, 201)["token"]
      assert [event] = events(:sign_in, ip)
      assert event.actor_id == user.id
      assert event.metadata == %{"method" => "password"}
    end

    test "a wrong password is not a sign-in", %{conn: conn} do
      user = seed_user()
      conn = post_sign_in(conn, %{"email" => to_string(user.email), "password" => "nope"})
      assert conn.status == 401
      assert events(:sign_in, ip_of(conn)) == []
    end
  end

  describe "sign_in (browser)" do
    test "the passkey ceremony records a passkey sign-in", %{conn: conn} do
      user = passkey_user(:editor)
      {:ok, _} = enroll(user, "ev-cred")
      ip = ip_of(conn)

      options = conn |> put_req_header("user-agent", @ua) |> post(~p"/auth/passkey/options")

      conn =
        options
        |> recycle()
        |> Map.put(:remote_ip, conn.remote_ip)
        |> put_req_header("user-agent", @ua)
        |> post(~p"/auth/passkey/verify", assertion("ev-cred"))

      assert json_response(conn, 200)["redirect_to"]
      assert [event] = events(:sign_in, ip)
      assert event.actor_id == user.id
      assert event.user_agent == @ua
      assert event.metadata == %{"method" => "passkey"}
    end

    test "a refused passkey assertion records no sign-in", %{conn: conn} do
      conn = post(conn, ~p"/auth/passkey/options")
      conn = post(conn, ~p"/auth/passkey/verify", assertion("ev-ghost"))
      assert conn.status == 401
      assert events(:sign_in, ip_of(conn)) == []
    end

    test "the code prompt completes the sign-in begun by another method", %{conn: conn} do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {user, token} = TwoFactorFixtures.with_first_factor_token(user)

      blob =
        PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, %{
          user
          | __metadata__: Map.put(user.__metadata__, :token, token)
        })

      conn =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> init_test_session(%{})
        |> put_session(:pending_2fa, blob)
        |> put_session(:sign_in_method, "magic_link")
        |> put_req_header("user-agent", @ua)
        |> post(~p"/sign-in/verify", %{"code" => TwoFactorFixtures.current_code(secret)})

      assert redirected_to(conn)
      assert [event] = events(:sign_in, ip_of(conn))
      assert event.actor_id == user.id
      assert event.metadata == %{"method" => "magic_link"}
      assert get_session(conn, :sign_in_method) == nil
    end

    test "AuthController.success records the method of its activity" do
      user = seed_user()
      ip = unique_ip()
      {user, token} = TwoFactorFixtures.with_first_factor_token(user)

      conn =
        build_conn()
        |> Map.put(
          :remote_ip,
          ip |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
        )
        |> Plug.Conn.assign(
          :current_org,
          Ash.get!(Accounts.Organization, org_id(), authorize?: false)
        )
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash([])

      KilnCMSWeb.AuthController.success(conn, {:magic_link, :sign_in}, user, token)

      assert [event] = events(:sign_in, ip)
      assert event.actor_id == user.id
      assert event.metadata == %{"method" => "magic_link"}
    end

    test "no org, no event" do
      user = seed_user()
      before = length(events())
      conn = Plug.Test.conn(:get, "/")
      assert :ok = AuthEvents.signed_in(conn, user, "password")
      assert length(events()) == before
    end

    test "a user being erased is not written into the log" do
      user = seed_user(%{anonymized_at: DateTime.utc_now()})
      ip = unique_ip()
      conn = org_request_conn(ip)
      assert :ok = AuthEvents.signed_in(conn, user, "password")
      assert events(:sign_in, ip) == []
    end

    test "a recorder failure never breaks the sign-in" do
      user = seed_user()
      handler = "auth-ev-failed-#{uniq()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:kiln_cms, :security, :event_failed],
        fn _e, _m, meta, _ -> send(test_pid, {:failed, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_org, %{id: Ash.UUID.generate()})

      assert :ok = AuthEvents.signed_in(conn, user, "password")
      assert_received {:failed, %{type: :sign_in}}
    end
  end

  defp org_request_conn(ip) do
    parts = ip |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

    Plug.Test.conn(:get, "/")
    |> Map.put(:remote_ip, parts)
    |> Plug.Conn.assign(:current_org, %{id: org_id()})
  end

  describe "sign_in_failed (password)" do
    test "a wrong password records the known account, the address and the agent" do
      user = seed_user()
      ip = unique_ip()

      assert {:error, _} = sign_in(to_string(user.email), "wrong", ctx(ip))

      assert [event] = events(:sign_in_failed, ip)
      assert event.actor_id == user.id
      assert event.actor_label == to_string(user.email)
      assert event.user_agent == @ua
      assert event.metadata == %{"method" => "password", "reason" => "invalid_credentials"}
    end

    test "an unknown address records no actor, no label and no address text" do
      ip = unique_ip()
      email = "ghost-#{uniq()}@example.com"

      assert {:error, _} = sign_in(email, "wrong", ctx(ip))

      assert [event] = events(:sign_in_failed, ip)
      assert event.actor_id == nil
      assert event.actor_label == nil
      assert event.target_id == nil
      refute inspect(event) =~ email
      refute inspect(event) =~ "ghost-"
    end

    test "known and unknown addresses are refused the same way" do
      user = seed_user()
      {:error, known} = sign_in(to_string(user.email), "wrong", ctx(unique_ip()))
      {:error, unknown} = sign_in("ghost-#{uniq()}@example.com", "wrong", ctx(unique_ip()))

      assert known.__struct__ == unknown.__struct__
    end

    test "failures are sampled per address" do
      user = seed_user()
      ip = unique_ip()

      for _ <- 1..8, do: sign_in(to_string(user.email), "wrong", ctx(ip))

      # The default sample cap is 5 per address per window; the rest are dropped.
      assert length(events(:sign_in_failed, ip)) == 5
    end

    test "nothing is recorded without a request context, or with no org" do
      user = seed_user()
      before = length(events())

      assert {:error, _} = sign_in(to_string(user.email), "wrong", %{})

      assert {:error, _} =
               sign_in(to_string(user.email), "wrong", %{security_request: %{ip: unique_ip()}})

      assert length(events()) == before
    end

    test "a successful first factor records nothing" do
      user = seed_user()
      ip = unique_ip()

      assert {:ok, _} = sign_in(to_string(user.email), @password, ctx(ip))

      assert Enum.filter(events(), &(&1.ip == ip)) == []
    end

    test "a recorder fault does not change the refusal" do
      user = seed_user()

      {:error, clean} = sign_in(to_string(user.email), "wrong", ctx(unique_ip()))

      {:error, broken} =
        sign_in(to_string(user.email), "wrong", ctx(unique_ip(), Ash.UUID.generate()))

      assert clean.__struct__ == broken.__struct__
    end

    test "the headless door records the refusal from the request" do
      user = seed_user()

      conn =
        build_conn() |> post_sign_in(%{"email" => to_string(user.email), "password" => "nope"})

      assert conn.status == 401
      assert [event] = events(:sign_in_failed, ip_of(conn))
      assert event.actor_id == user.id
      assert event.user_agent == @ua
    end
  end

  describe "sign_in_failed (another site's account)" do
    defp events_in(org_id) do
      Event |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!(authorize?: false, tenant: org_id)
    end

    defp member_of_org!(user, org),
      do: KilnCMS.OrgFixtures.grant_audiences(user, [:member], org.id)

    test "an address that exists only on site B is recorded on site A like an unknown one" do
      site_b = KilnCMS.OrgFixtures.org("sec-b")
      victim = seed_user() |> member_of_org!(site_b)
      ip_known = unique_ip()
      ip_unknown = unique_ip()

      assert {:error, _} = sign_in(to_string(victim.email), "wrong", ctx(ip_known))
      assert {:error, _} = sign_in("ghost-#{uniq()}@example.com", "wrong", ctx(ip_unknown))

      assert [theirs] = events(:sign_in_failed, ip_known)
      assert [ghost] = events(:sign_in_failed, ip_unknown)

      assert theirs.actor_id == nil
      assert theirs.actor_label == nil
      assert theirs.target_id == nil
      refute inspect(theirs) =~ to_string(victim.email)

      shape = &Map.take(&1, [:type, :actor_id, :actor_label, :target_type, :target_id, :metadata])
      assert shape.(theirs) == shape.(ghost)
    end

    test "a member of the event's org is labelled" do
      site_a = KilnCMS.OrgFixtures.org("sec-a")
      member = seed_user() |> member_of_org!(site_a)
      ip = unique_ip()

      assert {:error, _} = sign_in(to_string(member.email), "wrong", ctx(ip, site_a.id))

      assert [event] = Enum.filter(events_in(site_a.id), &(&1.ip == ip))
      assert event.actor_id == member.id
      assert event.actor_label == to_string(member.email)
    end

    test "a refused second factor of an account that is not a member is not labelled" do
      site_b = KilnCMS.OrgFixtures.org("sec-b2")
      user = seed_user() |> member_of_org!(site_b)
      ip = unique_ip()

      AuthEvents.second_factor_failed(ctx(ip), user)

      assert [event] = events(:sign_in_failed, ip)
      assert event.actor_id == nil
      assert event.actor_label == nil
    end

    test "a lockout of an account that is not a member is not labelled" do
      site_b = KilnCMS.OrgFixtures.org("sec-b3")
      user = seed_user() |> member_of_org!(site_b)
      ip = unique_ip()

      AuthEvents.locked(ctx(ip), user, "second_factor", "second_factor", user.id)

      assert [event] = Enum.filter(events(), &(&1.type == :sign_in_locked and &1.ip == ip))
      assert event.actor_id == nil
      assert event.actor_label == nil
    end

    test "a sampled-out failure performs no account lookup" do
      user = seed_user()
      ip = unique_ip()
      test_pid = self()
      handler = "lookup-count-#{uniq()}"

      for _ <- 1..5, do: sign_in(to_string(user.email), "wrong", ctx(ip))
      assert length(events(:sign_in_failed, ip)) == 5

      :telemetry.attach(
        handler,
        [:kiln_cms, :repo, :query],
        fn _e, _m, %{query: query}, _ ->
          if self() == test_pid and query =~ ~s(FROM "users"), do: send(test_pid, :user_read)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      AuthEvents.sign_in_failed(ctx(ip), to_string(user.email), "password", "invalid_credentials")

      refute_received :user_read
      assert length(events(:sign_in_failed, ip)) == 5
    end
  end

  describe "second factor" do
    test "a refused code is a failed sign-in against the account" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      ip = unique_ip()

      assert :invalid = SecondFactor.check(user, "000000", context: ctx(ip))

      assert [event] = events(:sign_in_failed, ip)
      assert event.actor_id == user.id
      assert event.metadata == %{"method" => "second_factor", "reason" => "invalid_code"}
    end

    test "a correct code records no failure" do
      {user, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      ip = unique_ip()

      assert {:ok, _} =
               SecondFactor.check(user, TwoFactorFixtures.current_code(secret), context: ctx(ip))

      assert Enum.filter(events(), &(&1.ip == ip)) == []
    end

    test "a recovery code records its use and the codes left, with the actor" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {user, [code | _] = codes} = TwoFactorFixtures.with_recovery_codes(user)
      ip = unique_ip()

      assert {:ok, _} = SecondFactor.check(user, code, context: ctx(ip))

      assert [event] = events(:recovery_code_used, ip)
      assert event.actor_id == user.id
      assert event.actor_label == to_string(user.email)
      assert event.user_agent == @ua
      assert event.metadata == %{"remaining" => length(codes) - 1}
    end

    test "a wrong recovery code records no use" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {user, _codes} = TwoFactorFixtures.with_recovery_codes(user)
      ip = unique_ip()

      assert :invalid = SecondFactor.check(user, "not-a-code", context: ctx(ip))
      assert events(:recovery_code_used, ip) == []
    end

    test "a recovery code used with no request context records nothing" do
      {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
      {user, [code | _]} = TwoFactorFixtures.with_recovery_codes(user)

      assert {:ok, _} = SecondFactor.check(user, code)
      assert events_for(user) == []
    end
  end

  describe "credential changes" do
    defp enrol_totp(user, context) do
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
      code = TwoFactorFixtures.current_code(staged)
      Accounts.confirm_totp(staged, %{code: code}, actor: user, context: context)
    end

    test "enrolling and removing TOTP are recorded with the kind" do
      user = seed_user()
      ip = unique_ip()

      assert {:ok, enrolled} = enrol_totp(user, ctx(ip))

      assert [added] = events(:second_factor_enrolled, ip)
      assert added.actor_id == user.id
      assert added.user_agent == @ua
      assert added.target_id == user.id
      assert added.metadata == %{"kind" => "totp"}

      code = TwoFactorFixtures.current_code(enrolled.totp_secret)

      assert {:ok, _} =
               Accounts.disable_totp(enrolled, %{code: code}, actor: user, context: ctx(ip))

      assert [removed] = events(:second_factor_removed, ip)
      assert removed.actor_id == user.id
      assert removed.metadata == %{"kind" => "totp"}
    end

    test "a refused code enrols nothing and records nothing" do
      user = seed_user()
      ip = unique_ip()
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

      assert {:error, _} =
               Accounts.confirm_totp(staged, %{code: "000000"}, actor: user, context: ctx(ip))

      assert events(:second_factor_enrolled, ip) == []
    end

    test "the event and the change commit together: no event, no enrolment" do
      user = seed_user()
      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
      code = TwoFactorFixtures.current_code(staged)

      # An org that does not exist makes the in-transaction write fail.
      assert {:error, _} =
               Accounts.confirm_totp(staged, %{code: code},
                 actor: user,
                 context: ctx(unique_ip(), Ash.UUID.generate())
               )

      refute Accounts.totp_enabled?(Ash.get!(User, user.id, authorize?: false))
    end

    test "adding and removing a passkey record the name, for the owner" do
      user = seed_user()
      ip = unique_ip()

      assert {:ok, passkey} =
               Accounts.register_passkey_credential(
                 %{
                   user_id: user.id,
                   name: "Work laptop",
                   credential_id: "cred-#{uniq()}",
                   public_key: :erlang.term_to_binary(%{}),
                   sign_count: 0
                 },
                 actor: user,
                 authorize?: false,
                 context: ctx(ip)
               )

      assert [added] = events(:passkey_added, ip)
      assert added.actor_id == user.id
      assert added.user_agent == @ua
      assert added.metadata == %{"name" => "Work laptop"}

      assert :ok = Accounts.remove_passkey(passkey, actor: user, context: ctx(ip))

      assert [removed] = events(:passkey_removed, ip)
      assert removed.actor_id == user.id
      assert removed.target_id == user.id
      assert removed.metadata == %{"name" => "Work laptop"}
    end

    test "a passkey changed with no request context records nothing" do
      user = seed_user()
      {:ok, passkey} = enroll(user, "quiet-cred")
      assert :ok = Accounts.remove_passkey(passkey, actor: user)
      assert events_for(user) == []
    end
  end

  describe "LiveView doors" do
    test "the sign-in page records a refused password with the socket's client", %{conn: conn} do
      user = seed_user()
      {conn, _key} = KilnCMS.RateLimitHelpers.client_conn(conn)
      ip = ip_of(conn)
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      params = [user: %{email: to_string(user.email), password: "wrong"}]
      view |> form("#user-password-sign-in-with-password", params) |> render_change()
      assert events(:sign_in_failed, ip) == [], "typing is not an attempt"

      view |> form("#user-password-sign-in-with-password", params) |> render_submit()

      assert [event] = events(:sign_in_failed, ip)
      assert event.actor_id == user.id
      assert event.org_id == org_id()
      assert event.metadata == %{"method" => "password", "reason" => "invalid_credentials"}
    end

    test "settings enrolment and removal are recorded from the socket", %{conn: conn} do
      user = seed_user()
      {:ok, signed_in} = sign_in(to_string(user.email), @password, %{})
      {conn, _key} = KilnCMS.RateLimitHelpers.client_conn(conn)
      ip = ip_of(conn)

      conn =
        conn
        |> init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)

      {:ok, lv, _html} = live(conn, ~p"/editor/settings")
      lv |> element("button", "Enable two-factor authentication") |> render_click()

      current = Ash.get!(User, user.id, authorize?: false)

      lv
      |> form("#confirm-totp-form", %{"code" => TwoFactorFixtures.current_code(current)})
      |> render_submit()

      assert [enrolled] = events(:second_factor_enrolled, ip)
      assert enrolled.actor_id == user.id
      assert enrolled.org_id == org_id()
      assert enrolled.metadata == %{"kind" => "totp"}

      current = Ash.get!(User, user.id, authorize?: false)

      lv
      |> form("#disable-totp-form", %{"code" => TwoFactorFixtures.current_code(current)})
      |> render_submit()

      assert [removed] = events(:second_factor_removed, ip)
      assert removed.actor_id == user.id
    end
  end
end
