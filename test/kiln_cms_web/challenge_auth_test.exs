defmodule KilnCMSWeb.ChallengeAuthTest do
  @moduledoc """
  Human verification at each door of sign-in and registration (#2249): the
  LiveView form, the no-JavaScript form POST behind it, and
  `POST /api/auth/sign_in`.

  Refusals first: what a refused attempt looks like on each door, that a known
  and an unknown address see the same thing, and that the client-address axis
  is read on all three. Then what an admitted attempt and an untouched door
  look like.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes node-wide config.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures
  import KilnCMS.EnumerationAssertions
  import KilnCMS.RateLimitHelpers, only: [client_conn: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User
  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Gate

  @password "password123456"
  @sign_in_form "form[action='/auth/user/password/sign_in']"
  @register_form "form[action='/auth/user/password/register']"

  defp email, do: "door-#{System.unique_integer([:positive])}@example.com"

  defp user!(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # Earlier attempts on `address`, as admitted sign-ins spend them.
  defp attempts(address, n) do
    Enum.each(1..n//1, fn _ ->
      AccountThrottle.consume(address)
      AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))
    end)
  end

  # Past the client-address threshold, the way the action counts it: the free
  # attempts spent and the failures recorded.
  defp failing_address!(ip) do
    ctx = %{security_request: %{ip: ip, user_agent: nil}}

    for _ <- 1..Challenge.threshold(:ip) do
      KilnCMS.Accounts.ThrottleStore.hit(
        "challenge:free_signin_ip",
        ip,
        Challenge.threshold(:ip_window),
        1_000_000
      )

      Gate.record_sign_in_failure(ctx)
    end

    :ok
  end

  defp widget?(html), do: html =~ ~s(phx-hook="Challenge")

  setup do
    enable!()
    :ok
  end

  describe "the LiveView sign-in, refused" do
    test "shows the widget with the reason once the address needs a challenge" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      {:ok, view, html} = live(conn, ~p"/sign-in")
      refute widget?(html)

      html =
        view
        |> form(@sign_in_form, user: %{email: address, password: @password})
        |> render_submit()

      assert widget?(html)
      assert html =~ "Complete the human-verification check below, then sign in again."
      assert html =~ "user-password-sign-in-with-password-challenge-1"
      assert html =~ ~s(data-sitekey="test-site-key")
      assert html =~ ~s(data-action="sign_in")
      assert html =~ ~s(name="user[challenge_token]")

      # Never an inline script: the hook loads the provider's.
      widget =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="challenge"]))
        |> LazyHTML.to_html()

      assert widget =~ "challenge-token"
      refute widget =~ "<script"

      # A refused token says so, and draws a fresh widget for the next try.
      # The token is the hook's to write, so it goes in as submitted data.
      html =
        view
        |> form(@sign_in_form, user: %{email: address, password: @password})
        |> render_submit(%{user: %{challenge_token: "fail"}})

      assert html =~ "The human-verification check didn&#39;t pass. Complete it again."
      assert html =~ "user-password-sign-in-with-password-challenge-2"
    end

    test "a known and an unknown address render the same page" do
      known = email()
      unknown = email()
      user!(known)
      attempts(known, Challenge.threshold(:account))
      attempts(unknown, Challenge.threshold(:account))

      submit = fn address ->
        {conn, _ip} = client_conn(build_conn())
        {:ok, view, _html} = live(conn, ~p"/sign-in")

        view
        |> form(@sign_in_form, user: %{email: address, password: "not-the-password"})
        |> render_submit()
      end

      html =
        assert_indistinguishable(fn -> submit.(known) end, fn -> submit.(unknown) end, [
          known,
          unknown
        ])

      assert html =~ "Complete the human-verification check below"
    end

    test "the client-address axis, from the socket's security context" do
      {conn, ip} = client_conn(build_conn())
      failing_address!(ip)

      # Shown before the first submit: the page already knows.
      {:ok, view, html} = live(conn, ~p"/sign-in")
      assert widget?(html)
      refute html =~ "Complete the human-verification check below"

      address = email()
      user!(address)

      html =
        view
        |> form(@sign_in_form, user: %{email: address, password: @password})
        |> render_submit()

      assert html =~ "Complete the human-verification check below, then sign in again."
    end
  end

  describe "the LiveView sign-in, forged host" do
    test "a join URL naming another host cannot vouch for a token solved there" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      {:ok, view, _html} = live(conn, "http://evil.example.net/sign-in")

      html =
        view
        |> form(@sign_in_form, user: %{email: address, password: @password})
        |> render_submit(%{user: %{challenge_token: "wrong-host"}})

      assert html =~ "The human-verification check didn&#39;t pass. Complete it again."
      assert AccountThrottle.sign_in_attempts(address) == Challenge.threshold(:account)
    end
  end

  describe "the LiveView sign-in, admitted" do
    test "a passing token signs in" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form(@sign_in_form, user: %{email: address, password: @password})
      |> render_submit()

      view
      |> form(@sign_in_form, user: %{email: address, password: @password})
      |> render_submit(%{user: %{challenge_token: "pass"}})

      assert_received {:challenge_verify, "pass", _opts}
      assert AccountThrottle.sign_in_attempts(address) == 0
    end

    test "with nothing configured the page is exactly what it was" do
      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, enabled_html} = live(conn, ~p"/sign-in")

      Application.put_env(
        :kiln_cms,
        Challenge,
        Keyword.put(Application.get_env(:kiln_cms, Challenge), :provider, nil)
      )

      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, disabled_html} = live(conn, ~p"/sign-in")

      assert observe(enabled_html, []) == observe(disabled_html, [])
      refute widget?(enabled_html)
    end

    test "?challenge=1 draws the widget from the first render" do
      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, html} = live(conn, ~p"/sign-in?challenge=1")
      assert widget?(html)
    end

    test "the fallback names only ways in this page has" do
      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, html} = live(conn, ~p"/sign-in?challenge=1")

      assert html =~ "Use a passkey or email yourself a sign-in link."
      refute html =~ "single sign-on."
    end
  end

  describe "the LiveView registration" do
    test "under :always shows the widget from the first render and refuses without a token" do
      enable!(registration: :always)
      {conn, _ip} = client_conn(build_conn())
      {:ok, view, html} = live(conn, ~p"/register")

      assert html =~ "user-password-register-with-password-challenge-0"
      assert html =~ ~s(data-action="register")
      assert html =~ "Ask a site administrator to invite you instead."

      address = email()

      html =
        view
        |> form(@register_form,
          user: %{email: address, password: @password, password_confirmation: @password}
        )
        |> render_submit()

      assert html =~ "Complete the human-verification check below, then register again."

      assert {:ok, nil} =
               KilnCMS.Accounts.get_user_by_email(address,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "under :adaptive shows nothing to a first-time address" do
      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, html} = live(conn, ~p"/register")
      refute html =~ "user-password-register-with-password-challenge"
    end
  end

  describe "the form POST, refused" do
    defp post_sign_in(conn, address, password, extra \\ %{}) do
      conn
      |> Plug.Test.init_test_session(%{})
      |> post(~p"/auth/user/password/sign_in", %{
        "user" => Map.merge(%{"email" => address, "password" => password}, extra)
      })
    end

    test "redirects back with ?challenge=1 and the reason, never 'incorrect password'" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      conn = post_sign_in(conn, address, @password)

      assert redirected_to(conn) == "/sign-in?challenge=1"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Complete the human-verification check below, then sign in again."
    end

    test "a known and an unknown address redirect alike" do
      known = email()
      unknown = email()
      user!(known)
      attempts(known, Challenge.threshold(:account))
      attempts(unknown, Challenge.threshold(:account))

      seen =
        assert_indistinguishable(
          fn -> post_sign_in(elem(client_conn(build_conn()), 0), known, "wrong") end,
          fn -> post_sign_in(elem(client_conn(build_conn()), 0), unknown, "wrong") end,
          [known, unknown]
        )

      assert seen.headers == [{"location", "/sign-in?challenge=1"}]
    end

    test "the client-address axis, from the conn's security context" do
      {conn, ip} = client_conn(build_conn())
      failing_address!(ip)
      address = email()
      user!(address)

      assert redirected_to(post_sign_in(conn, address, @password)) == "/sign-in?challenge=1"

      conn = post_sign_in(elem(client_conn(build_conn()), 0), address, @password)
      refute redirected_to(conn) =~ "challenge"
    end

    test "a site's own host cannot weaken the deployment-wide mode" do
      org = KilnCMS.OrgFixtures.org("challenge-host")
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      conn = post_sign_in(%{conn | host: "#{org.slug}.localhost"}, address, @password)
      assert redirected_to(conn) == "/sign-in?challenge=1"
    end

    test "a forged Host cannot vouch for a token solved on that host" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      # The fake answers "solved on evil.example.net", and the request names it.
      conn =
        post_sign_in(%{conn | host: "evil.example.net"}, address, @password, %{
          "challenge_token" => "wrong-host"
        })

      assert redirected_to(conn) == "/sign-in?challenge=1"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The human-verification check didn't pass. Complete it again."
    end

    test "a TOTP account that passes the challenge goes on to its second factor" do
      {user, _secret} = KilnCMS.TwoFactorFixtures.enabled_user(role: :editor)
      attempts(to_string(user.email), Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      conn =
        post_sign_in(conn, to_string(user.email), KilnCMS.TwoFactorFixtures.password(), %{
          "challenge_token" => "pass"
        })

      assert redirected_to(conn) =~ "/sign-in/verify"
    end

    test "a registration POST under :always redirects to /register?challenge=1" do
      enable!(registration: :always)
      {conn, _ip} = client_conn(build_conn())

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/auth/user/password/register", %{
          "user" => %{
            "email" => email(),
            "password" => @password,
            "password_confirmation" => @password
          }
        })

      assert redirected_to(conn) == "/register?challenge=1"
    end
  end

  describe "POST /api/auth/sign_in" do
    defp api_sign_in(conn, address, password, extra \\ %{}) do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/auth/sign_in",
        Map.merge(%{"email" => address, "password" => password}, extra)
      )
    end

    test "is untouched while api_sign_in is off, past every threshold" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, ip} = client_conn(build_conn())
      failing_address!(ip)

      conn = api_sign_in(conn, address, "wrong")

      assert json_response(conn, 401)["errors"] == [
               %{
                 "status" => "401",
                 "code" => "invalid_credentials",
                 "detail" => "Invalid email or password"
               }
             ]

      assert json_response(
               api_sign_in(elem(client_conn(build_conn()), 0), address, @password),
               201
             )

      refute_received {:challenge_verify, _, _}
    end

    test "answers challenge_required with what a client needs to draw the widget" do
      enable!(api_sign_in: true)
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      assert [error] = json_response(api_sign_in(conn, address, @password), 401)["errors"]
      assert error["code"] == "challenge_required"

      assert error["meta"] == %{
               "provider" => "fake",
               "site_key" => "test-site-key",
               "script_url" => "https://challenge.test/api.js?render=explicit",
               "action" => "sign_in",
               "global" => "kilnFakeChallenge",
               "onload_param" => nil,
               "render_options" => %{"response-field" => false},
               "action_option" => "action",
               "interactive" => false,
               "api" => "explicit_render"
             }

      conn =
        api_sign_in(elem(client_conn(build_conn()), 0), address, @password, %{
          "challenge_token" => "fail"
        })

      assert [%{"code" => "challenge_failed"}] = json_response(conn, 401)["errors"]

      conn =
        api_sign_in(elem(client_conn(build_conn()), 0), address, @password, %{
          "challenge_token" => "pass"
        })

      assert json_response(conn, 201)["token"]
    end

    test "a known and an unknown address get the same challenge_required" do
      enable!(api_sign_in: true)
      known = email()
      unknown = email()
      user!(known)
      attempts(known, Challenge.threshold(:account))
      attempts(unknown, Challenge.threshold(:account))

      seen =
        assert_indistinguishable(
          fn -> api_sign_in(elem(client_conn(build_conn()), 0), known, "wrong") end,
          fn -> api_sign_in(elem(client_conn(build_conn()), 0), unknown, "wrong") end,
          [known, unknown]
        )

      assert seen.status == 401
    end

    test "a TOTP account that passes the challenge gets the pending-token hand-off" do
      enable!(api_sign_in: true)
      {user, _secret} = KilnCMS.TwoFactorFixtures.enabled_user(role: :editor)
      attempts(to_string(user.email), Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      conn =
        api_sign_in(conn, to_string(user.email), KilnCMS.TwoFactorFixtures.password(), %{
          "challenge_token" => "pass"
        })

      body = json_response(conn, 200)
      assert body["two_factor_required"] == true
      assert is_binary(body["pending_token"])
      refute Map.has_key?(body, "token")
    end

    test "the client-address axis, and 503 once an outage closes it" do
      enable!(api_sign_in: true)
      {conn, ip} = client_conn(build_conn())
      failing_address!(ip)
      address = email()
      user!(address)

      assert [%{"code" => "challenge_required"}] =
               json_response(api_sign_in(conn, address, @password), 401)["errors"]

      ctx = %{security_request: %{ip: ip, user_agent: nil}}

      for _ <- 1..(Challenge.threshold(:ip_closed_after) - Challenge.threshold(:ip)),
          do: Gate.record_sign_in_failure(ctx)

      conn =
        build_conn()
        |> Map.put(:remote_ip, conn.remote_ip)
        |> api_sign_in(address, @password, %{"challenge_token" => "down"})

      assert [%{"code" => "challenge_unavailable"}] = json_response(conn, 503)["errors"]
      assert get_resp_header(conn, "retry-after") == ["30"]
    end
  end

  describe "with reCAPTCHA (#2249)" do
    setup do
      # Google's test keys answer this hostname; an operator lists it in
      # CHALLENGE_HOSTNAMES while using them.
      enable!(provider: "recaptcha", hostnames: ["testkey.google.com"])
      test = self()

      Req.Test.stub(Challenge, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:siteverify, conn.host, URI.decode_query(body)["response"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"success": true, "hostname": "testkey.google.com"}))
      end)

      :ok
    end

    test "the page draws reCAPTCHA's widget, told to wait for its onload callback" do
      {conn, _ip} = client_conn(build_conn())
      {:ok, _view, html} = live(conn, ~p"/sign-in?challenge=1")

      assert widget?(html)
      assert html =~ ~s(data-global="grecaptcha")
      assert html =~ ~s(data-onload-param="onload")
      assert html =~ ~s(data-action-option="")
      assert html =~ ~s(data-render-options="{}")
    end

    test "a sign-in carrying its token is verified at recaptcha.net and admitted" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form(@sign_in_form, user: %{email: address, password: @password})
      |> render_submit(%{user: %{challenge_token: "rc-token"}})

      assert_received {:siteverify, "www.recaptcha.net", "rc-token"}
      assert AccountThrottle.sign_in_attempts(address) == 0
    end

    test "the form POST without a token is refused, never admitted" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/auth/user/password/sign_in", %{
          "user" => %{"email" => address, "password" => @password}
        })

      assert redirected_to(conn) == "/sign-in?challenge=1"
      refute_received {:siteverify, _, _}
    end
  end

  describe "logs" do
    # The request log and the LiveView event log both print params through
    # `Phoenix.Logger.filter_values/1` with the app's `:filter_parameters`.
    test "never carry a challenge token, in either spelling" do
      params = %{
        "user" => %{
          "email" => "a@example.com",
          "challenge_token" => "secret-token-1",
          "password" => "pw"
        },
        "challenge_token" => "secret-token-2",
        "cf-turnstile-response" => "secret-token-3"
      }

      logged = params |> Phoenix.Logger.filter_values() |> inspect()

      refute logged =~ "secret-token"
      assert logged =~ "a@example.com"

      assert Phoenix.Logger.filter_values(params)["user"]["challenge_token"] == "[FILTERED]"
      assert Phoenix.Logger.filter_values(params)["cf-turnstile-response"] == "[FILTERED]"
    end

    test "never carry the field reCAPTCHA's own markup posts (#2249)" do
      params = %{"g-recaptcha-response" => "secret-token-4", "email" => "a@example.com"}

      assert Phoenix.Logger.filter_values(params) == %{
               "g-recaptcha-response" => "[FILTERED]",
               "email" => "a@example.com"
             }
    end

    test "the LiveView event log filters the submitted token" do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      address = email()
      attempts(address, Challenge.threshold(:account))
      {conn, _ip} = client_conn(build_conn())
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          view
          |> form(@sign_in_form, user: %{email: address, password: @password})
          |> render_submit(%{user: %{challenge_token: "pass-secret-token"}})
        end)

      # The event was logged, token key and all — just not its value.
      assert log =~ ~s("challenge_token" => "[FILTERED]")
      refute log =~ "pass-secret-token"
    end
  end
end
