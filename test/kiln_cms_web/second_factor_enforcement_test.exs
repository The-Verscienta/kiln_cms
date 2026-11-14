defmodule KilnCMSWeb.SecondFactorEnforcementTest do
  @moduledoc """
  Holding an account its site requires a second factor of (#2247), at every
  door: the browser gate (`KilnCMSWeb.Plugs.SecondFactorGate`) and its
  exempt routes, the LiveView gate (`KilnCMSWeb.SecondFactorGate`) on the
  disconnected render, the live mount, a policy change and the deadline, the
  sign-in doors (password, magic link, site SSO, OIDC, reset, passkey,
  remember-me), the headless sign-in, and a JWT on every request
  (`KilnCMSWeb.Plugs.SecondFactorBearer`), with API keys exempt.

  Every test runs on a site of its own (the policy cache is node-wide, so the
  default org is never given a policy), and signs in on that site's host. The
  setup page is not served on a site host, so a held account here is sent to
  the main host's (`SecondFactorGate.main_setup_url/0`); where the page is
  served (the main host, a console host), with `return_to` and the reminder,
  is `KilnCMSWeb.SecondFactorSetupHostTest`.
  The sockets, demo mode and the escape hatch need process-wide state and are
  in `KilnCMSWeb.SecondFactorSocketsTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PasskeyFixtures
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.AuthController
  alias KilnCMSWeb.Plugs.SecondFactorGate, as: GatePlug
  alias KilnCMSWeb.SecondFactorGate

  @moduletag :capture_log

  @password "password123456"
  @setup "/account/two-factor"

  @cookie to_string(
            KilnCMSWeb.SessionCookie.remember_me_key(
              Application.compile_env(:kiln_cms, :secure_session_cookie, false)
            )
          )

  # --- fixtures ----------------------------------------------------------------

  # A site that holds editors (and admins) from long ago, with no grace.
  defp held_site(slug), do: slug |> org() |> tap(&policy_row!(&1, :editors))

  defp password_sign_in(conn, user, site, params \\ %{}) do
    conn
    |> org_conn(site)
    |> Phoenix.ConnTest.init_test_session(%{})
    |> post(~p"/auth/user/password/sign_in", %{
      "user" => Map.merge(%{"email" => to_string(user.email), "password" => @password}, params)
    })
  end

  # `AuthController.success/4` as a strategy's callback reaches it, on `host`
  # with `site` resolved, as `SetTenant` would have.
  defp succeed(activity, user, site, host \\ nil) do
    {user, token} = KilnCMS.TwoFactorFixtures.with_first_factor_token(user)

    conn =
      build_conn()
      |> unique_ip()
      |> org_conn(site)
      |> then(&if(host, do: %{&1 | host: host}, else: &1))
      |> assign(:current_org, site)
      |> Plug.Conn.put_private(:phoenix_endpoint, KilnCMSWeb.Endpoint)
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> AuthController.success(activity, user, token)

    {conn, token}
  end

  defp canonical_host, do: URI.parse(KilnCMSWeb.Endpoint.url()).host

  # Where a site host sends a held account: the main host's setup page, with
  # no `return_to`.
  defp main_setup, do: SecondFactorGate.main_setup_url()

  defp held_events(user) do
    Repo.all(
      from(e in "security_events",
        where:
          e.type == "second_factor_required" and
            (e.target_id == type(^user.id, :binary_id) or
               e.actor_id == type(^user.id, :binary_id)),
        select: e.metadata
      )
    )
  end

  defp live_token_rows(token) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    Repo.all(
      from(t in "tokens",
        where: t.jti == ^jti and t.purpose == ^Accounts.Token.user_purpose(),
        select: t.jti
      )
    )
  end

  defp bearer(conn, site, token) do
    conn
    |> org_conn(site)
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp gql(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/gql", Jason.encode!(%{query: query}))
  end

  defp mint_key(owner) do
    admin = seed_user(%{role: :admin})

    owner.id
    |> Accounts.mint_api_key!("sf", DateTime.add(DateTime.utc_now(), 30, :day), %{access: :read},
      actor: admin
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  # --- the browser gate --------------------------------------------------------

  describe "the browser gate" do
    test "a held editor's every page goes to the main host's setup page first",
         %{conn: conn} do
      site = held_site("sfe-pages")
      conn = signed_in(conn, editor(site), site)

      for path <- [
            ~p"/editor/overview",
            ~p"/editor/settings",
            ~p"/account",
            ~p"/membership",
            ~p"/editor/content/export.csv",
            ~p"/editor/security-log/export.csv",
            ~p"/media/#{Ash.UUID.generate()}/download",
            ~p"/",
            "/some-page"
          ] do
        held = get(conn, path)

        assert redirected_to(held) == main_setup(), "#{path} was not held"
      end
    end

    test "the redirect writes no session or cookie and is not cacheable", %{conn: conn} do
      site = held_site("sfe-cache")

      # A session from a real sign-in, carried by its cookie as a browser
      # would: a test session would be written on every response.
      # Read once first, so the sign-in's flash is already spent: taking it
      # writes the session, and that is not the gate's write. A page that
      # answers 200: a redirect keeps the flash.
      session =
        conn
        |> password_sign_in(editor(site), site)
        |> recycle()
        |> org_conn(site)
        |> get(~p"/developers")
        |> recycle()
        |> org_conn(site)

      for path <- [~p"/", "/some-page", ~p"/editor/overview"] do
        held = get(session, path)

        assert redirected_to(held) == main_setup()
        assert get_resp_header(held, "cache-control") == ["private, no-store"]
        assert get_resp_header(held, "set-cookie") == [], "#{path} wrote a cookie"
      end
    end

    test "a form post is held without a return_to", %{conn: conn} do
      site = held_site("sfe-post")

      held =
        conn
        |> signed_in(editor(site), site)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/billing/checkout", %{})

      assert redirected_to(held) == main_setup()
    end

    test "the exempt routes still answer", %{conn: conn} do
      site = "sfe-exempt" |> org() |> tap(&policy_row!(&1, :everyone))
      conn = signed_in(conn, viewer(site), site)

      # Not held, but not served on a site host either: the main host's.
      assert redirected_to(get(conn, ~p"/account/two-factor")) == main_setup()
      assert response(get(conn, ~p"/editor/account/export.json"), 200)
      assert html_response(get(conn, ~p"/access-denied"), 403)
      assert html_response(get(conn, ~p"/developers"), 200)
      assert redirected_to(get(conn, ~p"/api")) == ~p"/developers"
      refute redirected_to(get(conn, ~p"/locale/es")) =~ @setup

      portal =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> post(~p"/billing/portal", %{})

      refute portal.status == 302 and redirected_to(portal) =~ @setup
    end

    test "sign-in and sign-out stay reachable", %{conn: conn} do
      site = held_site("sfe-auth")
      conn = signed_in(conn, editor(site), site)

      refute get(conn, ~p"/sign-in").status == 302 and
               redirected_to(get(conn, ~p"/sign-in")) =~ @setup

      refute get(conn, ~p"/sign-out").resp_headers |> Map.new() |> Map.get("location", "") =~
               @setup
    end

    test "the exempt list, method and path" do
      exempt = fn method, path ->
        GatePlug.exempt?(%Plug.Conn{
          method: method,
          path_info: String.split(path, "/", trim: true)
        })
      end

      assert exempt.("GET", "/account/two-factor")
      assert exempt.("POST", "/billing/portal")
      assert exempt.("GET", "/editor/account/export.json")
      assert exempt.("GET", "/locale/fr")
      assert exempt.("GET", "/access-denied")
      assert exempt.("GET", "/developers")
      assert exempt.("GET", "/api")
      assert exempt.("GET", "/setup")
      assert exempt.("GET", "/preview/tok/live")
      assert exempt.("POST", "/newsletter/confirm/tok")

      refute exempt.("GET", "/account")
      refute exempt.("GET", "/billing/portal")
      refute exempt.("POST", "/billing/checkout")
      refute exempt.("GET", "/editor/account/export.csv")
      refute exempt.("POST", "/editor/account/export.json")
      refute exempt.("GET", "/editor/two-factor")
      refute exempt.("GET", "/account/two-factor/elsewhere")
      refute exempt.("GET", "/")
    end

    test "an image is served as anonymous rather than redirected" do
      site = held_site("sfe-media")
      user = editor(site)

      conn =
        build_conn()
        |> assign(:current_user, user)
        |> assign(:current_org, site)
        |> GatePlug.call(GatePlug.init(:read_only))

      refute conn.halted
      assert conn.assigns.current_user == nil
    end

    test "an account in its grace period, or holding a factor, is not held", %{conn: conn} do
      site =
        "sfe-grace"
        |> org()
        |> tap(&policy_row!(&1, :editors, grace_days: 30, since: DateTime.utc_now()))

      assert html_response(conn |> signed_in(editor(site), site) |> get(~p"/account"), 200)

      held = held_site("sfe-enrolled")
      enrolled = held |> editor() |> with_app()
      assert html_response(build_conn() |> signed_in(enrolled, held) |> get(~p"/account"), 200)
    end

    test "required on one site, off on another: the same account uses the other", %{conn: conn} do
      held = held_site("sfe-multi-a")
      free = org("sfe-multi-b")
      user = held |> editor() |> member!(free, :editor)

      assert redirected_to(conn |> signed_in(user, held) |> get(~p"/account")) =~ @setup
      assert html_response(build_conn() |> signed_in(user, free) |> get(~p"/account"), 200)
    end

    test "anonymous visitors are untouched", %{conn: conn} do
      site = held_site("sfe-anon")
      refute redirected_to(conn |> org_conn(site) |> get(~p"/editor/overview")) =~ @setup
    end

    test "once enrolled, the page is reachable", %{conn: conn} do
      site = held_site("sfe-enrol")
      user = editor(site)
      conn = signed_in(conn, user, site)

      assert redirected_to(get(conn, ~p"/account")) =~ @setup
      with_app(user)
      assert html_response(get(conn, ~p"/account"), 200)
    end
  end

  # --- the LiveView gate -------------------------------------------------------

  describe "the LiveView gate" do
    test "the disconnected render halts a held account, and spares the setup page" do
      site = held_site("sfe-lv-dead")
      user = editor(site)

      socket = %Phoenix.LiveView.Socket{
        view: KilnCMSWeb.OverviewLive,
        assigns: %{__changed__: %{}, current_user: user, current_org: site}
      }

      # No host is not a setup host: the main host's page.
      assert {:halt, halted} = SecondFactorGate.attach(socket, %{})
      assert {:redirect, %{external: external}} = halted.redirected
      assert external == main_setup()

      on_site = %{
        socket
        | host_uri: URI.parse("http://#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}")
      }

      assert {:halt, halted} = SecondFactorGate.attach(on_site, %{})
      assert {:redirect, %{external: ^external}} = halted.redirected

      on_main = %{socket | host_uri: URI.parse(KilnCMSWeb.Endpoint.url())}
      assert {:halt, halted} = SecondFactorGate.attach(on_main, %{})
      assert {:redirect, %{to: @setup}} = halted.redirected

      assert {:cont, setup} =
               SecondFactorGate.attach(%{socket | view: KilnCMSWeb.TwoFactorSetupLive}, %{})

      assert setup.redirected == nil
    end

    test "a live navigation to another console page is held", %{conn: conn} do
      site = org("sfe-lv-nav")
      user = editor(site)
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      # Turned on without telling the page: the next mount still finds it.
      policy_row!(site, :editors)

      assert {:error, {:redirect, %{to: to}}} = live_redirect(view, to: ~p"/editor/settings")
      assert to == main_setup()
    end

    test "an open page goes to setup when the policy starts holding it", %{conn: conn} do
      site = org("sfe-lv-pubsub")
      user = editor(site)
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      row = policy_row!(site, :editors)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        TwoFactorRequirement.topic(site.id),
        {:second_factor_policy_changed, TwoFactorRequirement.from_row(row)}
      )

      assert_redirect(view, main_setup(), 2_000)
    end

    test "an open page goes to setup at the deadline", %{conn: conn} do
      site = org("sfe-lv-deadline")
      # One day of grace that started a day ago, less a moment.
      since = DateTime.add(DateTime.utc_now(), -86_400 * 1000 + 600, :millisecond)
      policy_row!(site, :editors, grace_days: 1, since: since)
      user = editor(site)

      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")
      assert_redirect(view, main_setup(), 3_000)
    end

    test "a page whose account enrolled meanwhile is not bounced", %{conn: conn} do
      site = org("sfe-lv-enrolled")
      user = editor(site)
      {:ok, view, _html} = conn |> signed_in(user, site) |> live(~p"/editor/overview")

      with_app(user)
      row = policy_row!(site, :editors)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        TwoFactorRequirement.topic(site.id),
        {:second_factor_policy_changed, TwoFactorRequirement.from_row(row)}
      )

      assert render(view)
    end
  end

  # --- the sign-in doors -------------------------------------------------------

  describe "the browser sign-in doors" do
    test "a held password sign-in lands on the main host's setup, recorded once", %{conn: conn} do
      site = held_site("sfe-door-pw")
      user = editor(site)
      signed_in = password_sign_in(conn, user, site)

      assert redirected_to(signed_in) == main_setup()

      assert is_binary(get_session(signed_in, :user_token))

      # Held on every page after it, and recorded only once.
      followed = signed_in |> recycle() |> org_conn(site)
      assert redirected_to(get(followed, ~p"/editor/overview")) == main_setup()
      assert redirected_to(get(followed, ~p"/account")) == main_setup()

      assert [%{"surface" => "browser", "reason" => "not_enrolled", "tier" => "editor"}] =
               held_events(user)
    end

    test "in the grace period on a site host it goes on; the banner reminds", %{conn: conn} do
      site =
        "sfe-door-grace"
        |> org()
        |> tap(&policy_row!(&1, :editors, grace_days: 30, since: DateTime.utc_now()))

      assert redirected_to(password_sign_in(conn, editor(site), site)) == ~p"/account"
    end

    for {name, activity} <- [
          magic_link: {:magic_link, :sign_in},
          site_sso: {:site_sso, :callback},
          oidc: {:sso, :callback},
          reset: {:password, :reset}
        ] do
      test "#{name}: held lands on setup, grace on the reminder, an app at the prompt" do
        site = held_site("sfe-door-#{unquote(name)}")
        {held, _token} = succeed(unquote(Macro.escape(activity)), editor(site), site)
        assert redirected_to(held) == main_setup()

        # Where the page is served, it is the page itself, going on after.
        {held, _token} =
          succeed(unquote(Macro.escape(activity)), editor(site), site, canonical_host())

        assert redirected_to(held) =~ @setup <> "?return_to="
        refute redirected_to(held) =~ "reminder"

        # A just-provisioned account on a site with a grace period: the reminder.
        grace = "sfe-door-#{unquote(name)}-g" |> org()
        policy_row!(grace, :editors, grace_days: 14)

        fresh =
          seed_user(%{inserted_at: DateTime.utc_now()})
          |> then(fn user ->
            Ash.Seed.seed!(Accounts.OrgMembership, %{
              organization_id: grace.id,
              user_id: user.id,
              role: :editor
            })

            user
          end)

        # On the site host it goes on (the banner reminds); where the page is
        # served, the reminder.
        {went_on, _token} = succeed(unquote(Macro.escape(activity)), fresh, grace)
        refute redirected_to(went_on) =~ @setup

        {reminded, _token} =
          succeed(unquote(Macro.escape(activity)), fresh, grace, canonical_host())

        assert redirected_to(reminded) =~ @setup <> "?reminder=1"

        {prompted, _token} =
          succeed(unquote(Macro.escape(activity)), site |> editor() |> with_app(), site)

        assert redirected_to(prompted) == ~p"/sign-in/verify"
      end
    end

    test "a passkey sign-in completes where passkeys count", %{conn: conn} do
      site = org("sfe-door-passkey")
      user = passkey_editor(site)
      policy_row!(site, :editors)

      optioned = conn |> org_conn(site) |> post(~p"/auth/passkey/options")

      signed_in =
        optioned
        |> recycle()
        |> org_conn(site)
        |> Map.put(:remote_ip, optioned.remote_ip)
        |> post(~p"/auth/passkey/verify", assertion("sfe-pk-#{user.id}"))

      assert %{"redirect_to" => "/account"} = json_response(signed_in, 200)
      assert held_events(user) == []
    end

    test "the remember-me cookie signs in to a held session", %{conn: conn} do
      site = held_site("sfe-door-remember")
      user = editor(site)

      cookie =
        password_sign_in(conn, user, site, %{"remember_me" => "true"}).resp_cookies[@cookie]

      remembered =
        build_conn()
        |> unique_ip()
        |> org_conn(site)
        |> Plug.Test.put_req_cookie(@cookie, cookie.value)
        |> get(~p"/sign-in")

      assert remembered.assigns.current_user.id == user.id

      after_cookie = remembered |> recycle() |> org_conn(site) |> get(~p"/editor/overview")
      assert redirected_to(after_cookie) =~ @setup
    end
  end

  # Enrolled before the site requires anything: past the deadline an
  # enrolment needs the email proof (`RequireEnrolmentProof`), which is not
  # what these tests are about.
  defp passkey_editor(site) do
    user = editor(site)
    {:ok, _} = enroll(user, "sfe-pk-#{user.id}")
    user
  end

  describe "a passkey-only account past the deadline" do
    test "its password alone stops at the passkey prompt on the console host" do
      site = org("sfe-pko-console")
      user = passkey_editor(site)
      policy_row!(site, :editors)
      {prompted, token} = succeed({:password, :sign_in}, user, site, canonical_host())

      assert redirected_to(prompted) == ~p"/sign-in/verify"
      assert get_session(prompted, :user_token) == nil
      assert is_binary(get_session(prompted, :pending_2fa))
      assert live_token_rows(token) == []
    end

    test "and is refused on a host where the passkey cannot run" do
      site = org("sfe-pko-tenant")
      user = passkey_editor(site)
      policy_row!(site, :editors)
      {refused, token} = succeed({:password, :sign_in}, user, site)

      assert redirected_to(refused) == ~p"/sign-in"
      assert get_session(refused, :user_token) == nil
      assert get_session(refused, :pending_2fa) == nil
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ canonical_host()
      assert live_token_rows(token) == []

      assert [%{"surface" => "browser", "reason" => "passkey_host"}] = held_events(user)
    end

    test "before the deadline the same password completes" do
      site =
        "sfe-pko-grace"
        |> org()
        |> tap(&policy_row!(&1, :editors, grace_days: 30, since: DateTime.utc_now()))

      {signed_in, _token} = succeed({:password, :sign_in}, passkey_editor(site), site)

      assert redirected_to(signed_in) == ~p"/account"
      assert is_binary(get_session(signed_in, :user_token))
    end

    test "the password that stops at the passkey prompt does not clear the sign-in budget" do
      site = org("sfe-pko-budget")
      user = passkey_editor(site)
      policy_row!(site, :editors)
      email = to_string(user.email)
      AccountThrottle.reset(email)

      sign_in = fn org_id ->
        User
        |> AshAuthentication.Info.strategy!(:password)
        |> AshAuthentication.Strategy.action(
          :sign_in,
          %{"email" => email, "password" => @password},
          context: %{Recorder.tenant_key() => org_id}
        )
      end

      assert {:ok, _user} = sign_in.(site.id)
      assert {:ok, _user} = sign_in.(site.id)
      assert AccountThrottle.sign_in_attempts(email) == 2

      # Where nothing requires a second factor, the password is the sign-in.
      free = org("sfe-pko-budget-free")
      member!(user, free, :editor)
      assert {:ok, _user} = sign_in.(free.id)
      assert AccountThrottle.sign_in_attempts(email) == 0
    end
  end

  # --- the headless door -------------------------------------------------------

  describe "POST /api/auth/sign_in" do
    defp api_sign_in(conn, user, site) do
      conn
      |> org_conn(site)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth/sign_in", %{"email" => to_string(user.email), "password" => @password})
    end

    # Rows that would still authenticate as this account.
    defp live_tokens_of(user) do
      subject = AshAuthentication.user_to_subject(user)

      Repo.all(
        from(t in "tokens",
          where: t.subject == ^subject and t.purpose == ^Accounts.Token.user_purpose(),
          select: t.jti
        )
      )
    end

    test "held: 403, no token, and the one minted is revoked", %{conn: conn} do
      site = held_site("sfe-api-held")
      user = editor(site)

      assert %{"errors" => [%{"code" => "second_factor_required", "meta" => meta}]} =
               conn |> api_sign_in(user, site) |> json_response(403)

      assert meta["setup_url"] =~ @setup
      assert {:ok, _, _} = DateTime.from_iso8601(meta["deadline"])
      refute Map.has_key?(meta, "reason")
      assert live_tokens_of(user) == []
      assert [%{"surface" => "api", "reason" => "not_enrolled"}] = held_events(user)
    end

    test "a passkey-only account past the deadline: 403 passkey_only", %{conn: conn} do
      site = org("sfe-api-pko")
      user = passkey_editor(site)
      policy_row!(site, :editors)

      assert %{"errors" => [%{"code" => "second_factor_required", "meta" => meta}]} =
               conn |> api_sign_in(user, site) |> json_response(403)

      assert meta["reason"] == "passkey_only"
      assert [%{"reason" => "headless_passkey"}] = held_events(user)
    end

    test "in the grace period the token says until when", %{conn: conn} do
      site =
        "sfe-api-grace"
        |> org()
        |> tap(&policy_row!(&1, :editors, grace_days: 30, since: DateTime.utc_now()))

      assert %{"token" => _, "second_factor" => %{"required" => true, "deadline" => deadline}} =
               conn |> api_sign_in(editor(site), site) |> json_response(201)

      assert {:ok, _, _} = DateTime.from_iso8601(deadline)
    end

    test "not required, the answer is as it always was", %{conn: conn} do
      site = org("sfe-api-free")
      body = conn |> api_sign_in(editor(site), site) |> json_response(201)
      assert Map.keys(body) |> Enum.sort() == ["token", "user"]
    end

    test "an authenticator-app holder still owes a code", %{conn: conn} do
      site = held_site("sfe-api-app")

      assert %{"two_factor_required" => true} =
               conn |> api_sign_in(site |> editor() |> with_app(), site) |> json_response(200)
    end
  end

  # --- a JWT on every request --------------------------------------------------

  describe "a JWT on every request" do
    test "one minted in grace works until the deadline, then is refused everywhere", %{conn: conn} do
      site = org("sfe-jwt")
      row = policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
      user = editor(site)
      token = jwt(user)
      conn = bearer(conn, site, token)

      assert json_response(get(conn, ~p"/api/locales"), 200)
      assert %{"data" => _} = conn |> gql("{ __typename }") |> json_response(200)

      end_grace!(row)

      assert %{"errors" => [%{"code" => "second_factor_required", "meta" => %{"setup_url" => _}}]} =
               conn |> get(~p"/api/locales") |> json_response(403)

      refused = get(conn, "/api/json/entries/published")
      assert refused.status == 403
      assert get_resp_header(refused, "cache-control") == ["private, no-store"]

      assert %{"errors" => [%{"extensions" => %{"code" => "second_factor_required"}}]} =
               conn |> gql("{ __typename }") |> json_response(403)

      query = "/gql?" <> URI.encode_query(%{query: "{ __typename }"})
      assert get(conn, query).status == 403
      assert get(conn, ~p"/api/feed").status == 403
    end

    test "an enrolled account's JWT, and an unrequired site's, work", %{conn: conn} do
      site = held_site("sfe-jwt-ok")
      enrolled = site |> editor() |> with_app()
      assert json_response(conn |> bearer(site, jwt(enrolled)) |> get(~p"/api/locales"), 200)

      free = org("sfe-jwt-free")
      user = site |> editor() |> member!(free, :editor)
      assert json_response(build_conn() |> bearer(free, jwt(user)) |> get(~p"/api/locales"), 200)

      assert build_conn() |> bearer(site, jwt(user)) |> get(~p"/api/locales") |> Map.get(:status) ==
               403
    end

    test "API keys are exempt for a held owner", %{conn: conn} do
      site = held_site("sfe-key")
      key = mint_key(editor(site))
      conn = bearer(conn, site, key)

      assert json_response(get(conn, ~p"/api/locales"), 200)
      assert %{"data" => _} = conn |> gql("{ __typename }") |> json_response(200)

      mcp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/mcp",
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: %{
              protocolVersion: "2024-11-05",
              capabilities: %{},
              clientInfo: %{name: "t", version: "0"}
            }
          })
        )

      assert %{"result" => _} = json_response(mcp, 200)
    end

    test "/mcp takes no JWT, held or not, nor a stale or garbage bearer", %{conn: conn} do
      site = held_site("sfe-mcp")
      user = editor(site)
      {:ok, expired, _} = AshAuthentication.Jwt.token_for_user(user, %{"exp" => 1})

      for token <- [jwt(user), "garbage", expired] do
        refused =
          conn
          |> bearer(site, token)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))

        assert refused.status == 401
      end
    end
  end

  # --- a passkey-only account's password-only access ---------------------------

  describe "a passkey-only account's password-only access past the deadline" do
    defp grace_row(site),
      do: policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())

    defp marked(conn, user, site, marker) do
      token = jwt(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

      conn
      |> org_conn(site)
      |> Phoenix.ConnTest.init_test_session(%{
        "user_token" => token,
        "sign_in" => Map.put(marker, "jti", jti)
      })
    end

    test "a JWT minted in grace stops at the deadline", %{conn: conn} do
      site = org("sfe-pko-jwt")
      user = passkey_editor(site)
      row = grace_row(site)
      conn = bearer(conn, site, jwt(user))

      assert json_response(get(conn, ~p"/api/locales"), 200)

      end_grace!(row)

      assert %{"errors" => [%{"code" => "second_factor_required"}]} =
               conn |> get(~p"/api/locales") |> json_response(403)

      assert conn |> gql("{ __typename }") |> json_response(403)
    end

    test "a JWT minted on a site that does not cover it is refused where one does",
         %{conn: conn} do
      held = org("sfe-pko-cross")
      user = passkey_editor(held)
      policy_row!(held, :editors)
      free = org("sfe-pko-cross-free")
      member!(user, free, :editor)

      assert %{"token" => token} =
               conn |> api_sign_in(user, free) |> json_response(201)

      assert json_response(build_conn() |> bearer(free, token) |> get(~p"/api/locales"), 200)

      assert build_conn() |> bearer(held, token) |> get(~p"/api/locales") |> Map.get(:status) ==
               403
    end

    test "a password session from before the deadline goes to the passkey prompt",
         %{conn: conn} do
      site = org("sfe-pko-session")
      user = passkey_editor(site)
      policy_row!(site, :editors)

      session = marked(conn, user, site, %{"method" => "password"})

      for path <- [~p"/account", ~p"/account/two-factor", ~p"/editor/account/export.json"] do
        held = get(session, path)
        assert redirected_to(held) == ~p"/sign-in/verify", path
        assert get_resp_header(held, "cache-control") == ["private, no-store"]
      end

      # A tenant host cannot run the passkey: the session is signed out there.
      token = get_session(session, "user_token")
      refused = get(session, ~p"/sign-in/verify")
      assert redirected_to(refused) == ~p"/sign-in"
      assert get_session(refused, "user_token") == nil
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ canonical_host()
      assert live_token_rows(token) == []
    end

    test "on the console host it is turned into a pending passkey step-up" do
      site = org("sfe-pko-console-session")
      user = passkey_editor(site)
      policy_row!(site, :editors)
      token = jwt(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

      conn =
        build_conn()
        |> unique_ip()
        |> Map.put(:host, canonical_host())
        |> Map.put(:path_info, ["account"])
        |> assign(:current_org, site)
        |> assign(:current_user, user)
        |> Plug.Conn.put_private(:phoenix_endpoint, KilnCMSWeb.Endpoint)
        |> Plug.Test.init_test_session(%{
          "user_token" => token,
          "sign_in" => %{"jti" => jti, "method" => "remember_me"}
        })
        |> Phoenix.Controller.fetch_flash([])
        |> KilnCMSWeb.Plugs.PasskeyStepUp.call([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in/verify"
      assert get_session(conn, "user_token") == nil
      assert is_binary(get_session(conn, :pending_2fa))
      assert get_session(conn, :sign_in_method) == "remember_me"
      assert conn.assigns.current_user == nil
      assert live_token_rows(token) == []
    end

    test "a remember-me cookie does not restore it", %{conn: conn} do
      site = org("sfe-pko-remember")
      user = passkey_editor(site)
      row = grace_row(site)

      # Ticked during the grace period, when the password alone still signed in.
      cookie =
        password_sign_in(conn, user, site, %{"remember_me" => "true"}).resp_cookies[@cookie]

      assert cookie.value
      end_grace!(row)

      remembered =
        build_conn()
        |> unique_ip()
        |> org_conn(site)
        |> Plug.Test.put_req_cookie(@cookie, cookie.value)
        |> get(~p"/sign-in")

      assert remembered.assigns.current_user == nil
      assert get_session(remembered, "user_token") == nil
      assert %{max_age: 0} = remembered.resp_cookies[@cookie]
    end

    test "a session that passed the passkey still works", %{conn: conn} do
      site = org("sfe-pko-verified")
      user = passkey_editor(site)
      policy_row!(site, :editors)

      for marker <- [
            %{"method" => "passkey"},
            %{"method" => "password", "second_factor_at" => System.system_time(:second)}
          ] do
        assert html_response(conn |> marked(user, site, marker) |> get(~p"/account"), 200)
      end
    end

    test "the LiveView gate sends it to the prompt too, setup page included" do
      site = org("sfe-pko-lv")
      user = passkey_editor(site)
      policy_row!(site, :editors)
      token = jwt(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
      session = %{"user_token" => token, "sign_in" => %{"jti" => jti, "method" => "password"}}

      for view <- [KilnCMSWeb.OverviewLive, KilnCMSWeb.TwoFactorSetupLive] do
        socket = %Phoenix.LiveView.Socket{
          view: view,
          assigns: %{__changed__: %{}, current_user: user, current_org: site}
        }

        assert {:halt, halted} = SecondFactorGate.attach(socket, session)
        assert {:redirect, %{to: "/sign-in/verify"}} = halted.redirected
      end

      verified = put_in(session, ["sign_in", "method"], "passkey")

      assert {:cont, _socket} =
               SecondFactorGate.attach(
                 %Phoenix.LiveView.Socket{
                   view: KilnCMSWeb.OverviewLive,
                   assigns: %{__changed__: %{}, current_user: user, current_org: site}
                 },
                 verified
               )
    end
  end
end
