defmodule KilnCMSWeb.SignInRateLimitTest do
  @moduledoc """
  Every credential form on the auth pages is charged a per-IP bucket
  (#715, #724).

  They submit inside LiveComponents over `/live`, so they pass no plug and the
  router's limits never see them — the limit is charged on the *action*
  instead, from a client address `KilnCMSWeb.SignInLive` attaches to the form's
  context. These tests cover both halves: that the view attaches it, and that
  each action charges it.

  #715 wired only `sign_in_with_password`; #724 found the other three. Note that
  all four forms render on **all three** of `/sign-in`, `/register` and
  `/reset` — `Components.Password` emits the sign-in block unconditionally and
  hides the rest with a CSS class — so which page a caller is on does not bound
  which form they can submit, and each needs its own charge.

  The `:auth` limit is left at its real value and every test works on an
  address of its own — the action tests build one into the context by hand, the
  page tests hand one to the page with `client_conn/1`. Tightening the limit
  app-wide would be the obvious way to write this and is wrong: the limit is
  global while the counters are per-address, so a tightened limit refuses every
  *other* suite's requests from `127.0.0.1` for as long as this file runs.

  Measuring on a per-test address rather than on the loopback bucket is also
  what keeps the delta assertions below stable — see
  `KilnCMS.RateLimitHelpers` for the cleaner race that made them flaky (#877).

  Not `async: true`: `Application.put_env` is global and this file sets
  `AccountThrottle`'s budget for one test. The rate-limit table is node-wide
  too, but that alone would no longer force it — no address here is shared.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.RateLimitHelpers
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias AshAuthentication.Info
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.RateLimit

  @password "password123456"

  defp auth_limit do
    {limit, _scale} = Map.fetch!(RateLimit.limits(), :auth)
    limit
  end

  defp email, do: "signin-ip-#{System.unique_integer([:positive])}@example.com"

  defp context(ip), do: [context: ThrottleSignIn.client_ip_context(ip)]

  # Spend `n` of the address's budget without going near the action — no bcrypt,
  # no account budget, nothing but the counter this is about.
  defp spend(ip, n), do: Enum.each(1..n//1, fn _ -> RateLimit.check(:auth, ip) end)

  defp spent(ip), do: spent("auth", ip)

  defp user!(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp sign_in(address, password, opts \\ []) do
    strategy = Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(
      strategy,
      :sign_in,
      %{"email" => address, "password" => password},
      opts
    )
  end

  describe "the per-IP charge on the action" do
    test "a spent address is refused, correct password included" do
      address = email()
      user!(address)
      ip = client_ip()
      spend(ip, auth_limit())

      # The whole point: the address is out of budget, so the *right* password
      # is refused too. Otherwise an attacker's final correct guess still lands.
      assert {:error, _} = sign_in(address, @password, context(ip))

      # ...and only for that address. A different client is unaffected.
      assert {:ok, _user} = sign_in(address, @password, context(client_ip()))
    end

    test "one attempt costs exactly one of the budget" do
      address = email()
      user!(address)
      ip = client_ip()

      # Counted, not inferred from a refusal: a "did it deny?" assertion holds
      # under both one charge and two, so it cannot catch a caller that already
      # passed `Plugs.RateLimit` being charged again here.
      assert {:error, _} = sign_in(address, "wrong", context(ip))
      assert spent(ip) == 1

      assert {:ok, _user} = sign_in(address, @password, context(ip))
      assert spent(ip) == 2
    end

    test "an attempt with no client address in context is not charged" do
      address = email()
      user!(address)
      ip = client_ip()
      spend(ip, auth_limit())

      # Every HTTP entry point already paid `Plugs.RateLimit, :auth`; the
      # context key is what distinguishes them, and without it the exhausted
      # bucket above is nothing to do with this attempt.
      assert {:ok, _user} = sign_in(address, @password)
    end

    test "a refused address does not spend the account's budget" do
      address = email()
      user!(address)
      ip = client_ip()
      budget = 3

      # Tightened so the assertion can actually fail: the suite-wide account
      # budget is effectively unlimited (see `config/test.exs`), which would
      # make "the account was not locked out" true for the wrong reason.
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])
      Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(previous, :budget, budget))

      on_exit(fn ->
        Application.put_env(:kiln_cms, AccountThrottle, previous)
        AccountThrottle.reset(address)
      end)

      spend(ip, auth_limit())
      for _ <- 1..(budget * 3), do: sign_in(address, "wrong", context(ip))

      # A flood from one address must not be able to lock out the accounts it
      # names — that would make the account budget the attacker's lever.
      assert {:ok, _user} = sign_in(address, @password, context(client_ip()))
    end

    test "building and validating the form costs nothing — only executing does" do
      address = email()
      user!(address)
      ip = client_ip()
      strategy = Info.strategy!(User, :password)

      # The trap this guards: preparations run when a query is BUILT, and
      # `AshPhoenix.Form` builds one per `validate/2`. The sign-in form is
      # `phx-change="change"`, so a charge in `prepare/3` costs one unit per
      # keystroke — a user typing a 20-character password would lock themselves
      # out before submitting it, and merely loading the page would charge too.
      form =
        AshPhoenix.Form.for_action(User, strategy.sign_in_action_name,
          domain: KilnCMS.Accounts,
          as: "user",
          context: ThrottleSignIn.client_ip_context(ip)
        )

      Enum.reduce(1..10, form, fn n, form ->
        AshPhoenix.Form.validate(
          form,
          %{"email" => address, "password" => String.duplicate("x", n)},
          errors: false
        )
      end)

      assert spent(ip) == 0

      # ...and the attempt itself still is charged.
      assert {:error, _} = sign_in(address, "wrong", context(ip))
      assert spent(ip) == 1
    end

    test "a refused address mails nobody an attack alert" do
      address = email()
      user!(address)
      ip = client_ip()
      on_exit(fn -> AccountThrottle.reset(address) end)

      spend(ip, auth_limit())
      assert {:error, _} = sign_in(address, "wrong", context(ip))
      KilnCMS.DataCase.drain_oban()

      # The account refusal mails the owner "someone is guessing at your
      # password". The address refusal must not: the address says nothing about
      # whose account was aimed at, so an attacker who has spent their own
      # budget would otherwise still get to pick whose inbox rings.
      assert_no_email_sent()
    end

    test "the refusal surfaces as the same generic failure a wrong password does" do
      address = email()
      user!(address)
      ip = client_ip()

      {:error, wrong_password} = sign_in(address, "wrong", context(ip))
      spend(ip, auth_limit())
      {:error, throttled} = sign_in(address, @password, context(ip))

      # Deliberately NOT a timing claim: the address refusal skips the simulated
      # bcrypt that the *account* refusal pays, and does so on purpose — see
      # `ThrottleSignIn.refuse_address/1`. What is asserted is that the caller
      # renders it as the same failure, so the UI cannot tell a user (or an
      # attacker) which of the two refused them.
      assert wrong_password.__struct__ == throttled.__struct__
      assert Exception.message(wrong_password) == Exception.message(throttled)
    end
  end

  describe "KilnCMSWeb.SignInLive" do
    test "attaches the socket's client address to the sign-in form context", %{conn: conn} do
      {conn, ip} = client_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      form_context = :sys.get_state(view.pid).socket.assigns.context

      # The address the socket peered from, threaded through under the key the
      # preparation reads — the two ends agreeing is the thing that can silently
      # break. Asserted against the address this test handed the handshake and
      # not against loopback, so a view that stopped resolving one (or answered
      # a constant) fails rather than passing on `ConnTest`'s default peer.
      assert ThrottleSignIn.client_ip_context(ip) == Map.take(form_context, [:kiln_client_ip])
    end

    test "a real submit through the page charges the bucket exactly once", %{conn: conn} do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      # The one test that walks the whole seam this change exists to create:
      # the view's `@context` assign → `Components.SignIn` → `Components.Password`
      # → `SignInForm` → `AshPhoenix.Form` → the `Ash.Query` context → the
      # preparation. Every other test in this file hand-builds the context and
      # so would stay green if any link in that chain were renamed or dropped —
      # which would silently turn the control off.
      {conn, ip} = client_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      before = spent(ip)

      # The `remote_ip` half of `client_conn/1` is otherwise unpinned: `before`
      # is read *after* the page load, so dropping it would only move the
      # baseline from 1 to 0 and every delta below would still hold — silently
      # putting every auth page load in this file back on `auth:127.0.0.1`.
      # It is also the one assertion in the suite that the plug door and the
      # socket door spell the same client the same way (`RateLimit.client_key/1`).
      assert before == 1, "the disconnected render did not charge :auth on this test's address"

      view
      |> form("#user-password-sign-in-with-password", user: %{email: address, password: "wrong"})
      |> render_change()

      assert spent(ip) == before, "a phx-change must not spend the budget"

      view
      |> form("#user-password-sign-in-with-password", user: %{email: address, password: "wrong"})
      |> render_submit()

      assert spent(ip) == before + 1
    end

    test "a real registration through the page charges :register exactly once", %{conn: conn} do
      # The seam that matters most: registration was the unbounded one, and the
      # form is reachable from every auth page. Walks view context ->
      # Components.SignIn -> Components.Password -> RegisterForm ->
      # AshPhoenix.Form -> the changeset context -> the change.
      {conn, ip} = client_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/register")
      before = spent("register", ip)
      address = email()

      params = %{email: address, password: @password, password_confirmation: @password}

      view
      |> form("#user-password-register-with-password-wrapper form", user: params)
      |> render_change()

      assert spent("register", ip) == before,
             "a phx-change must not spend the budget — the form is phx-change, so a " <>
               "charge at build time costs one unit per keystroke"

      view
      |> form("#user-password-register-with-password-wrapper form", user: params)
      |> render_submit()

      assert spent("register", ip) == before + 1
    end

    test "a real reset request through the page charges :auth once", %{conn: conn} do
      {conn, ip} = client_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/reset")
      before = spent("auth", ip)

      view
      |> form("#user-password-request-password-reset-token-wrapper form", user: %{email: email()})
      |> render_submit()

      assert spent("auth", ip) == before + 1
    end

    test "a real magic-link request through the page charges :auth once", %{conn: conn} do
      {conn, ip} = client_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      before = spent("auth", ip)

      view
      # Selected by its action rather than an id: unlike the other three, the
      # magic-link component renders no wrapper with a stable id.
      |> form(~s(form[action="/auth/user/magic_link/request"]), user: %{email: email()})
      |> render_submit()

      assert spent("auth", ip) == before + 1
    end

    test "every credential form is reachable from every auth page", %{conn: conn} do
      # The reason each one needs its own charge rather than relying on the
      # page it "belongs" to. If this ever stops being true the three tests
      # above are testing less than they look like they are.
      wrappers = [
        "user-password-sign-in-with-password-wrapper",
        "user-password-register-with-password-wrapper",
        "user-password-request-password-reset-token-wrapper",
        "user-magic-link-request-magic-link"
      ]

      for path <- [~p"/sign-in", ~p"/register", ~p"/reset"] do
        # Its own address too, though it measures nothing — so this file leaves
        # `auth:127.0.0.1` alone entirely rather than only where it asserts.
        {page_conn, _ip} = client_conn(conn)
        {:ok, _view, html} = live(page_conn, path)

        for wrapper <- wrappers do
          assert html =~ wrapper, "#{wrapper} is not rendered on #{path}"
        end
      end
    end

    test "the endpoint gives the socket what the address is resolved from" do
      # `:peer_data`/`:x_headers` are the only source: the session is signed at
      # the disconnected render and replayable, so it would name whichever
      # address fetched the page rather than the one submitting now.
      [{"/live", _socket, opts}] =
        Enum.filter(KilnCMSWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/live" end)

      for transport <- [:websocket, :longpoll] do
        connect_info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)
        assert :peer_data in connect_info
        assert :x_headers in connect_info
      end
    end
  end
end
