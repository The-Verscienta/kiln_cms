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

  The `:auth` limit is left at its real value and each test spends its own
  address's bucket by hand. Tightening the limit app-wide would be the obvious
  way to write this and is wrong: the limit is global while the counters are
  per-address, so a tightened limit refuses every *other* suite's requests from
  `127.0.0.1` for as long as this file runs.

  Not `async: true`: `KilnCMSWeb.RateLimit`'s table is node-wide. Every address
  used here is unique, so the buckets themselves cannot collide with another
  file's.
  """
  use KilnCMSWeb.ConnCase, async: false

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

  # A fresh address per call, so a spent bucket is never one another test (or
  # another file) is also spending — which is the whole reason these tests can
  # leave the real limit alone. Private range, spread across a /8 so the counter
  # would have to run 16M calls before it repeated.
  defp client_ip do
    n = System.unique_integer([:positive])
    "10.#{n |> div(65_536) |> rem(256)}.#{n |> div(256) |> rem(256)}.#{rem(n, 256)}"
  end

  defp context(ip), do: [context: ThrottleSignIn.client_ip_context(ip)]

  # Spend `n` of the address's budget without going near the action — no bcrypt,
  # no account budget, nothing but the counter this is about.
  defp spend(ip, n), do: Enum.each(1..n//1, fn _ -> RateLimit.check(:auth, ip) end)

  # How much of the address's budget has been charged. Reads Hammer's own table,
  # whose rows are `{{key, window}, count, expiry}`, because nothing else can
  # distinguish "charged once" from "charged eleven times" below the limit.
  defp spent(ip), do: spent("auth", ip)

  defp spent(bucket, ip) do
    KilnCMSWeb.RateLimit
    |> :ets.tab2list()
    |> Enum.filter(fn {{key, _window}, _count, _expiry} -> key == "#{bucket}:" <> ip end)
    |> Enum.map(fn {_key, count, _expiry} -> count end)
    |> Enum.sum()
  end

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
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      form_context = :sys.get_state(view.pid).socket.assigns.context

      # `ConnTest`'s socket peers from the loopback address. What matters is
      # that *an* address is threaded through under the key the preparation
      # reads — the two ends agreeing is the thing that can silently break.
      assert ThrottleSignIn.client_ip_context("127.0.0.1") ==
               Map.take(form_context, [:kiln_client_ip])
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
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      before = spent("127.0.0.1")

      view
      |> form("#user-password-sign-in-with-password", user: %{email: address, password: "wrong"})
      |> render_change()

      assert spent("127.0.0.1") == before, "a phx-change must not spend the budget"

      view
      |> form("#user-password-sign-in-with-password", user: %{email: address, password: "wrong"})
      |> render_submit()

      assert spent("127.0.0.1") == before + 1
    end

    test "a real registration through the page charges :register exactly once", %{conn: conn} do
      # The seam that matters most: registration was the unbounded one, and the
      # form is reachable from every auth page. Walks view context ->
      # Components.SignIn -> Components.Password -> RegisterForm ->
      # AshPhoenix.Form -> the changeset context -> the change.
      {:ok, view, _html} = live(conn, ~p"/register")
      before = spent("register", "127.0.0.1")
      address = email()

      params = %{email: address, password: @password, password_confirmation: @password}

      view
      |> form("#user-password-register-with-password-wrapper form", user: params)
      |> render_change()

      assert spent("register", "127.0.0.1") == before,
             "a phx-change must not spend the budget — the form is phx-change, so a " <>
               "charge at build time costs one unit per keystroke"

      view
      |> form("#user-password-register-with-password-wrapper form", user: params)
      |> render_submit()

      assert spent("register", "127.0.0.1") == before + 1
    end

    test "a real reset request through the page charges :auth once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/reset")
      before = spent("auth", "127.0.0.1")

      view
      |> form("#user-password-request-password-reset-token-wrapper form", user: %{email: email()})
      |> render_submit()

      assert spent("auth", "127.0.0.1") == before + 1
    end

    test "a real magic-link request through the page charges :auth once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sign-in")
      before = spent("auth", "127.0.0.1")

      view
      # Selected by its action rather than an id: unlike the other three, the
      # magic-link component renders no wrapper with a stable id.
      |> form(~s(form[action="/auth/user/magic_link/request"]), user: %{email: email()})
      |> render_submit()

      assert spent("auth", "127.0.0.1") == before + 1
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
        {:ok, _view, html} = live(conn, path)

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
