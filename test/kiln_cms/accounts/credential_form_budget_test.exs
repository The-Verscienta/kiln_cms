defmodule KilnCMS.Accounts.CredentialFormBudgetTest do
  @moduledoc """
  Every credential form is bounded per client address (#715, #724).

  #715 closed this for `sign_in_with_password`: the browser sign-in submits as a
  LiveView event over `/live`, so it passes no router pipeline and no plug can
  reach it. The fix threads the socket's own client address into the action
  context and charges the bucket from the action.

  The same argument covered three more forms and none of them was wired.
  Registration was the sharp one — one websocket replaying `submit` was
  unlimited account creation, a bcrypt hash and a confirmation mail per event,
  from one address, with nothing counting. All four are on `/sign-in`,
  `/register` *and* `/reset`, because `Components.Password` renders the sign-in
  block unconditionally and only hides the others with a CSS class, so which
  page the caller is on does not bound which form they can submit.

  `async: false`: the buckets are node-wide ETS and this file tightens them.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.RateLimitHelpers

  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.RateLimit

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, RateLimit, [])

    Application.put_env(
      :kiln_cms,
      RateLimit,
      Keyword.put(
        previous,
        :limits,
        # MERGED, not replaced: replacing drops `:api`, `:gql`, `:delivery` and
        # `:probe` from the suite's effective-infinity back to production values
        # for this file's duration, which would bite the moment anything here
        # made an HTTP call.
        Map.merge(KilnCMSWeb.RateLimit.limits(), %{
          # Widened windows, not tightened — a fixed-window rollover mid-test is
          # the #697 flake shape.
          register: {2, :timer.hours(1)},
          auth: {2, :timer.hours(1)}
        })
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, RateLimit, previous) end)
    :ok
  end

  defp context(ip), do: ThrottleSignIn.client_ip_context(ip)

  defp email, do: "credform-#{System.unique_integer([:positive])}@example.com"

  defp register(ip, address) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(
      strategy,
      :register,
      %{
        "email" => address,
        "password" => @password,
        "password_confirmation" => @password
      },
      context: context(ip)
    )
  end

  defp request_reset(ip, address) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :reset_request, %{"email" => address},
      context: context(ip)
    )
  end

  defp request_magic_link(ip, address) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    AshAuthentication.Strategy.action(strategy, :request, %{"email" => address},
      context: context(ip)
    )
  end

  describe "registration" do
    test "is bounded per client address" do
      # The whole point: before this, the loop below never ended.
      ip = client_ip()

      assert {:ok, _user} = register(ip, email())
      assert {:ok, _user} = register(ip, email())
      assert {:error, _refused} = register(ip, email())
    end

    test "a different address has its own budget" do
      # A per-IP bound must not become a global one — that would be an outage,
      # not a control.
      first = client_ip()
      second = client_ip()

      assert {:ok, _} = register(first, email())
      assert {:ok, _} = register(first, email())
      assert {:error, _} = register(first, email())

      assert {:ok, _} = register(second, email())
    end

    test "does not spend the sign-in budget" do
      # Its own bucket, deliberately: sharing `:auth` would let a burst of
      # legitimate sign-ups lock *sign-in* for everyone behind one office NAT —
      # the shared-NAT trade residual risk 4 already records.
      ip = client_ip()

      assert {:ok, _} = register(ip, email())
      assert {:ok, _} = register(ip, email())
      assert {:error, _} = register(ip, email())

      assert :allow = RateLimit.check(:auth, ip)
    end

    test "a caller with no address in context is not charged" do
      # An absent address means a router pipeline already charged this request.
      # Charging anyway would bill every HTTP caller twice, halving a limit the
      # threat model states as one number.
      strategy = AshAuthentication.Info.strategy!(User, :password)

      for _ <- 1..5 do
        assert {:ok, _} =
                 AshAuthentication.Strategy.action(strategy, :register, %{
                   "email" => email(),
                   "password" => @password,
                   "password_confirmation" => @password
                 })
      end
    end
  end

  describe "the password-reset request" do
    test "is bounded per client address" do
      # A generic action — no `prepare`/`change` hook — so the charge wraps the
      # run. This is the test that the wrapper actually delegates.
      ip = client_ip()
      address = email()
      Ash.Seed.seed!(User, %{email: address, hashed_password: Bcrypt.hash_pwd_salt(@password)})

      assert :ok = request_reset(ip, address)
      assert :ok = request_reset(ip, address)

      # Refused loudly, like every other per-IP refusal here. The
      # indistinguishability this endpoint protects is between a known and an
      # unknown *address*; a throttle says nothing about any address, only that
      # the caller's own IP is out of budget — which they know.
      assert {:error, _refused} = request_reset(ip, address)
    end

    test "a real reset still sends when there is budget" do
      ip = client_ip()
      address = email()
      Ash.Seed.seed!(User, %{email: address, hashed_password: Bcrypt.hash_pwd_salt(@password)})

      assert :ok = request_reset(ip, address)
      drain_oban()

      assert_receive {:email, %{subject: subject}}, 100
      assert subject =~ "assword"
    end
  end

  describe "the magic-link request" do
    test "is bounded per client address" do
      ip = client_ip()
      address = email()
      Ash.Seed.seed!(User, %{email: address, hashed_password: Bcrypt.hash_pwd_salt(@password)})

      assert :ok = request_magic_link(ip, address)
      assert :ok = request_magic_link(ip, address)
      assert {:error, _refused} = request_magic_link(ip, address)
    end

    test "shares the sign-in bucket, so switching form buys no second budget" do
      ip = client_ip()
      address = email()
      Ash.Seed.seed!(User, %{email: address, hashed_password: Bcrypt.hash_pwd_salt(@password)})

      assert :ok = request_magic_link(ip, address)
      assert :ok = request_magic_link(ip, address)

      assert {:deny, _ms} = RateLimit.check(:auth, ip)
    end

    test "a spent budget stops the mail going out" do
      # The observable that matters, since the response shape is constant: past
      # the ceiling nothing reaches the sender.
      ip = client_ip()
      address = email()
      Ash.Seed.seed!(User, %{email: address, hashed_password: Bcrypt.hash_pwd_salt(@password)})

      assert :ok = request_magic_link(ip, address)
      drain_oban()
      assert_receive {:email, _first}, 100

      assert :ok = request_magic_link(ip, address)
      drain_oban()
      assert_receive {:email, _second}, 100

      # Budget spent.
      assert {:error, _refused} = request_magic_link(ip, address)
      drain_oban()
      refute_receive {:email, _third}, 100
    end
  end

  describe "the charge lands before the password is hashed" do
    test "the throttle is declared before the password hash" do
      # Asserted structurally rather than by timing. A "refused is faster than
      # allowed" assertion is the obvious test and the wrong one: bcrypt runs at
      # a reduced cost factor under test, so the ratio is small enough that a
      # loaded CI box flakes it — and a flaky security test gets muted, which
      # is worse than not having it.
      #
      # What actually holds the property is declaration order:
      # `Ash.Changeset.before_action/2` appends, so a charge declared above
      # `HashPasswordChange` runs first and a refusal never reaches the hash.
      # An ash_authentication release that prepends its changes, or a
      # reordering in `user.ex`, would silently restore a full bcrypt per
      # refused request — and this is what notices.
      changes =
        KilnCMS.Accounts.User
        |> Ash.Resource.Info.action(:register_with_password)
        |> Map.fetch!(:changes)
        |> Enum.map(fn
          %{change: {module, _opts}} -> module
          other -> other
        end)

      throttle = Enum.find_index(changes, &(&1 == KilnCMS.Accounts.Changes.ThrottleRegistration))

      hash =
        Enum.find_index(changes, &(&1 == AshAuthentication.Strategy.Password.HashPasswordChange))

      assert is_integer(throttle) and is_integer(hash)
      assert throttle < hash
    end
  end

  describe "the HTTP door charges the same bucket" do
    test "POST /auth/user/password/register spends :register, not :auth" do
      # `auth_routes` generates a real POST route for the non-JS fallback, on a
      # pipeline that charged `:auth` at 20/min — four times the ceiling the
      # LiveView door enforces, and it spent the SIGN-IN bucket doing it, which
      # is exactly the coupling `:register` exists to prevent.
      # On an address of this test's own, not the `build_conn/0` default: these
      # are delta assertions, and `auth:127.0.0.1` is the bucket the whole
      # suite charges, so its count is not this test's to reason about (#877).
      # `spent/2` sums every window for a key, and Hammer's minute cleaner
      # deletes closed windows — so a tick between these reads and the ones
      # below takes a stale window's count with it, and `== auth_before` fails
      # claiming the route "spent the sign-in bucket" when it did nothing.
      {conn, ip} = client_conn(Phoenix.ConnTest.build_conn())

      # Both baselines are 0 on a fresh address, so these are absolute counts
      # written as deltas. Asserted with `==`, not `>`: the regression #724
      # guards against is a DOUBLE charge — the plug charging `:register` and
      # the action charging it again — and `>` is satisfied by two just as
      # well as by one. The hour-wide scale this file sets makes a mid-test
      # window rollover impossible, so the tight assertion cannot flake.
      auth_before = spent("auth", ip)
      register_before = spent("register", ip)

      Phoenix.ConnTest.dispatch(
        conn,
        KilnCMSWeb.Endpoint,
        :post,
        "/auth/user/password/register",
        %{
          "user" => %{
            "email" => email(),
            "password" => @password,
            "password_confirmation" => @password
          }
        }
      )

      assert spent("register", ip) == register_before + 1,
             "the HTTP registration route did not charge :register exactly once"

      assert spent("auth", ip) == auth_before,
             "the HTTP registration route spent the sign-in bucket"
    end
  end

  describe "the context key" do
    test "is written and read through one function" do
      # Two spellings of the key would fail *silently*, because "no address in
      # context" is a legitimate state meaning a plug already charged this.
      assert %{} = ctx = ThrottleSignIn.client_ip_context("198.51.100.7")
      assert Map.fetch!(ctx, ThrottleSignIn.context_key()) == "198.51.100.7"
    end
  end
end
