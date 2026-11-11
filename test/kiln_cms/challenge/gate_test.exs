defmodule KilnCMS.Challenge.GateTest do
  @moduledoc """
  When a sign-in or a registration needs a human-verification challenge, and
  what an answer from the provider does to it (#2249).

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes application env
  and an OS variable, both node-wide.
  """
  use KilnCMS.DataCase, async: false

  # The crash and fail-closed cases log; the assertions are on the verdicts.
  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures
  import KilnCMS.RateLimitHelpers, only: [client_ip: 0]

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Challenge
  alias KilnCMS.Challenge.Gate

  @free_ip "challenge:free_signin_ip"
  @failed_ip "challenge:signin_ip"

  defp email, do: "gate-#{System.unique_integer([:positive])}@example.com"

  defp context(ip, surface \\ :browser) do
    Map.merge(%{security_request: %{ip: ip, user_agent: nil}}, Challenge.context(surface))
  end

  # Spend the account axis's free attempts without going near the gate.
  defp spend_account(address, n \\ Challenge.threshold(:account)),
    do:
      Enum.each(1..n//1, fn _ ->
        AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))
      end)

  defp spend_ip(ip, n \\ Challenge.threshold(:ip)),
    do: Enum.each(1..n//1, fn _ -> ThrottleStore.hit(@free_ip, ip, ip_window(), 1_000_000) end)

  defp ip_failures(ip, n),
    do: Enum.each(1..n//1, fn _ -> Gate.record_sign_in_failure(context(ip)) end)

  defp ip_window, do: Challenge.threshold(:ip_window)

  describe "a sign-in under :adaptive" do
    setup do
      enable!()
      :ok
    end

    test "below both thresholds needs nothing, and never asks the provider" do
      address = email()
      spend_account(address, Challenge.threshold(:account) - 1)

      assert Gate.sign_in(context(client_ip()), address, "fail") == :ok
      refute_received {:challenge_verify, _, _}
    end

    test "the account axis: attempts on the submitted address" do
      address = email()

      for _ <- 1..Challenge.threshold(:account),
          do: assert(Gate.sign_in(context(client_ip()), address, nil) == :ok)

      assert Gate.sign_in(context(client_ip()), address, nil) == {:refuse, :required}
      assert Gate.sign_in(context(client_ip()), address, "fail") == {:refuse, :failed}
      assert Gate.sign_in(context(client_ip()), address, "expired") == {:refuse, :failed}
      assert Gate.sign_in(context(client_ip()), address, "pass") == :ok
    end

    test "a completed sign-in gives the account its free attempts back" do
      address = email()
      spend_account(address)
      assert Gate.sign_in(context(client_ip()), address, nil) == {:refuse, :required}

      AccountThrottle.forgive(address)
      assert Gate.sign_in(context(client_ip()), address, nil) == :ok
    end

    test "the address axis: attempts from the caller's address" do
      ip = client_ip()

      for _ <- 1..Challenge.threshold(:ip),
          do: assert(Gate.sign_in(context(ip), email(), nil) == :ok)

      assert Gate.sign_in(context(ip), email(), nil) == {:refuse, :required}
      assert Gate.sign_in(context(ip), email(), "pass") == :ok

      # Another address is not affected.
      assert Gate.sign_in(context(client_ip()), email(), nil) == :ok
    end

    test "a successful sign-in hands the address's free attempt back" do
      ip = client_ip()
      spend_ip(ip)
      assert Gate.sign_in(context(ip), email(), nil) == {:refuse, :required}

      # The refused attempt spent one too; two successes clear both.
      Gate.record_sign_in_success(context(ip))
      Gate.record_sign_in_success(context(ip))
      assert Gate.sign_in(context(ip), email(), nil) == :ok
    end

    test "a simultaneous burst cannot all skip the challenge" do
      address = email()
      ip = client_ip()

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> Gate.sign_in(context(ip), address, nil) end)
        end)
        |> Task.await_many(10_000)

      # Both axes are spent atomically: the tighter one (the account's) bounds
      # how many get through without a challenge.
      free = Enum.count(results, &(&1 == :ok))
      assert free == Challenge.threshold(:account)
      assert Enum.count(results, &(&1 == {:refuse, :required})) == 20 - free
    end

    test "deciding never charges the account's budget or the failure counter" do
      address = email()
      ip = client_ip()

      for _ <- 1..10, do: Gate.sign_in(context(ip), address, nil)

      assert AccountThrottle.sign_in_attempts(address) == 0
      assert ThrottleStore.peek(@failed_ip, ip, ip_window()) == 0
    end

    test "verifies at most once per decision" do
      address = email()
      spend_account(address)

      assert Gate.sign_in(context(client_ip()), address, "pass") == :ok
      assert_received {:challenge_verify, "pass", opts}
      assert opts[:action] == "sign_in"
      refute_received {:challenge_verify, _, _}
    end

    test "a malformed token is refused without asking the provider" do
      address = email()
      spend_account(address)

      too_long = String.duplicate("a", 2049)

      for token <- [too_long, "pass\nthe-rest", 42, %{"x" => 1}] do
        assert Gate.sign_in(context(client_ip()), address, token) == {:refuse, :failed}
      end

      refute_received {:challenge_verify, _, _}
    end

    test "the client address is not sent to the provider unless the operator says so" do
      address = email()
      ip = client_ip()
      spend_account(address)

      Gate.sign_in(context(ip), address, "pass")
      assert_received {:challenge_verify, "pass", opts}
      assert opts[:remote_ip] == nil

      enable!(send_remote_ip: true)
      Gate.sign_in(context(ip), address, "pass")
      assert_received {:challenge_verify, "pass", opts}
      assert opts[:remote_ip] == ip
    end
  end

  describe "a sign-in when the provider cannot be asked" do
    setup do
      enable!()
      :ok
    end

    test "fails open on the account axis — the account's own budget is the bound" do
      address = email()
      spend_account(address)

      assert Gate.sign_in(context(client_ip()), address, "down") == :ok
    end

    test "fails open on the address axis until ip_closed_after, then closed" do
      ip = client_ip()
      spend_ip(ip)
      ip_failures(ip, Challenge.threshold(:ip))
      assert Gate.sign_in(context(ip), email(), "down") == :ok

      ip_failures(ip, Challenge.threshold(:ip_closed_after) - Challenge.threshold(:ip))
      assert Gate.sign_in(context(ip), email(), "down") == {:refuse, :unavailable}
    end

    test "a crash or a timeout is unavailable, never a pass by accident" do
      enable!(deadline: 50)
      ip = client_ip()
      spend_ip(ip)
      ip_failures(ip, Challenge.threshold(:ip_closed_after))

      assert Gate.sign_in(context(ip), email(), "crash") == {:refuse, :unavailable}
      assert Gate.sign_in(context(ip), email(), "slow") == {:refuse, :unavailable}
    end

    test "with no outage seen, a missing token is required" do
      address = email()
      spend_account(address)

      refute Challenge.outage?()
      assert Gate.sign_in(context(client_ip()), address, nil) == {:refuse, :required}
    end

    test "once an outage is seen, a missing token gets the same bounded fail-open" do
      address = email()
      ip = client_ip()
      spend_account(address)

      # Some attempt's token came back unavailable on this node.
      assert Challenge.verify(Challenge.config(), "down", :sign_in) ==
               {:error, {:unavailable, :transport}}

      assert Challenge.outage?()
      assert Gate.sign_in(context(ip), address, nil) == :ok

      # ...and closed past the address bound, exactly as a "down" token is.
      ip_failures(ip, Challenge.threshold(:ip_closed_after))
      assert Gate.sign_in(context(ip), address, nil) == {:refuse, :unavailable}

      # A token the provider refuses is still refused during an outage.
      assert Gate.sign_in(context(client_ip()), address, "fail") == {:refuse, :failed}
    end

    test "the outage lapses on its own" do
      enable!(outage_window: 50)
      Challenge.verify(Challenge.config(), "down", :sign_in)
      assert Challenge.outage?()

      Process.sleep(60)
      refute Challenge.outage?()
    end
  end

  describe "the hostname a token was solved on" do
    setup do
      enable!()
      address = email()
      spend_account(address)
      %{address: address}
    end

    test "any host of this deployment is accepted, not only the one dialled", %{address: address} do
      org = KilnCMS.OrgFixtures.org("gate")

      assert Gate.sign_in(context(client_ip()), address, "host:#{org.slug}.localhost") == :ok
      assert Gate.sign_in(context(client_ip()), address, "host:localhost") == :ok
    end

    test "a host the deployment does not serve is refused", %{address: address} do
      assert Gate.sign_in(context(client_ip()), address, "wrong-host") == {:refuse, :failed}
    end

    test "the operator can list hostnames of their own", %{address: address} do
      enable!(hostnames: ["Evil.Example.net"])
      assert Gate.sign_in(context(client_ip()), address, "wrong-host") == :ok
    end

    test "the operator can turn the hostname check off", %{address: address} do
      enable!(verify_hostname: false)
      assert Gate.sign_in(context(client_ip()), address, "wrong-host") == :ok
    end
  end

  describe "the headless door" do
    test "is never challenged while api_sign_in is off" do
      enable!(api_sign_in: false)
      address = email()
      spend_account(address)

      assert Gate.sign_in(context(client_ip(), :api), address, nil) == :ok
      refute_received {:challenge_verify, _, _}
    end

    test "is challenged like the browser once api_sign_in is on" do
      enable!(api_sign_in: true)
      address = email()
      spend_account(address)

      assert Gate.sign_in(context(client_ip(), :api), address, nil) == {:refuse, :required}
      assert Gate.sign_in(context(client_ip(), :api), address, "pass") == :ok
    end
  end

  describe "nothing is required" do
    test "with no provider configured" do
      address = email()
      for _ <- 1..10, do: assert(Gate.sign_in(context(client_ip()), address, nil) == :ok)
      assert Gate.registration(context(client_ip()), nil) == :ok
    end

    test "with the kill switch on" do
      enable!(disabled: true, registration: :always)
      address = email()

      for _ <- 1..10, do: assert(Gate.sign_in(context(client_ip()), address, nil) == :ok)
      assert Gate.registration(context(client_ip()), nil) == :ok
      refute Challenge.enabled?(Challenge.config())
    end

    test "with a provider named but no secret configured — and it says so" do
      enable!()
      System.delete_env(secret_var())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ets.match_delete(ThrottleStore.Local, {{:challenge_unusable_logged, :_}, :_, :_})
          assert Challenge.config().provider == nil
        end)

      assert log =~ "no usable secret key"
      refute log =~ "test-secret"
    end

    test "with an unknown provider or no site key" do
      enable!(provider: "nope")
      assert Challenge.config().provider == nil

      enable!(site_key: "")
      assert Challenge.config().provider == nil
    end

    test "with sign-in :off" do
      enable!(sign_in: :off)
      address = email()
      for _ <- 1..10, do: assert(Gate.sign_in(context(client_ip()), address, nil) == :ok)
    end
  end

  describe "the secret" do
    test "comes from a mounted file instead of the environment" do
      path = Path.join(System.tmp_dir!(), "kiln-challenge-#{System.unique_integer([:positive])}")
      File.write!(path, "file-secret\n")
      on_exit(fn -> File.rm(path) end)

      enable!(secret_key: {:file, %{"path" => path}})
      assert Challenge.config().provider == KilnCMS.ChallengeFake
      assert Challenge.verify(Challenge.config(), "pass", :sign_in) == :ok
    end

    test "is never read to decide whether the feature is on" do
      enable!(secret_key: {:file, %{"path" => "/nonexistent/kiln-challenge-secret"}})

      # Configured, so challenges stay on...
      assert Challenge.config().provider == KilnCMS.ChallengeFake

      # ...and a read that fails when a token is checked is unavailable —
      # the bounded fail-open — not "challenges off".
      # The error is logged at most once a minute per node: start this test
      # with that allowance unspent, whatever ran before it.
      KilnCMS.Accounts.ThrottleStore.Local.set(
        :challenge_secret_refused_logged,
        :timer.minutes(1),
        0
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Challenge.verify(Challenge.config(), "pass", :sign_in) ==
                   {:error, {:unavailable, :not_configured}}
        end)

      # Failing open on a bad secret is never silent.
      assert log =~ "could not use its secret key"
      refute log =~ "/nonexistent/kiln-challenge-secret"
      refute_received {:challenge_verify, _, _}
    end

    test "never comes from the database: a site could write that" do
      enable!(secret_key: {:database, %{"encrypted" => "x"}})
      assert Challenge.config().provider == nil
    end
  end

  describe "failures counted against an address" do
    test "only while sign-in is :adaptive" do
      enable!(sign_in: :off)
      ip = client_ip()
      Gate.record_sign_in_failure(context(ip))
      assert ThrottleStore.peek(@failed_ip, ip, ip_window()) == 0

      enable!()
      Gate.record_sign_in_failure(context(ip))
      assert ThrottleStore.peek(@failed_ip, ip, ip_window()) == 1
    end

    test "not at all without an address" do
      enable!()
      assert Gate.record_sign_in_failure(%{}) == :ok
      assert Gate.record_sign_in_success(%{}) == :ok
    end
  end

  describe "a registration" do
    test ":always asks every time, and an admitted one passes" do
      enable!(registration: :always)

      assert Gate.registration(context(client_ip()), nil) == {:refuse, :required}
      assert Gate.registration(context(client_ip()), "fail") == {:refuse, :failed}
      assert Gate.registration(context(client_ip()), "pass") == :ok
      assert_received {:challenge_verify, "pass", opts}
      assert opts[:action] == "register"
    end

    test ":adaptive asks once an address has registered past the threshold" do
      enable!(registration: :adaptive)
      ip = client_ip()

      for _ <- 1..Challenge.threshold(:registration) do
        assert Gate.registration(context(ip), nil) == :ok
      end

      assert Gate.registration(context(ip), nil) == {:refuse, :required}
      assert Gate.registration(context(ip), "pass") == :ok
      assert Gate.registration_preshow?(context(ip))
      refute Gate.registration_preshow?(context(client_ip()))
    end

    test "a simultaneous burst cannot all skip the challenge" do
      enable!(registration: :adaptive)
      ip = client_ip()

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> Gate.registration(context(ip), nil) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &(&1 == :ok)) == Challenge.threshold(:registration)
    end

    test "fails open while the provider is down — the :register bucket bounds it" do
      enable!(registration: :always)
      assert Gate.registration(context(client_ip()), "down") == :ok
    end

    test "a missing token during a seen outage fails open too" do
      enable!(registration: :always)
      refute Gate.registration(context(client_ip()), nil) == :ok

      Challenge.verify(Challenge.config(), "down", :register)
      assert Gate.registration(context(client_ip()), nil) == :ok
    end

    test ":off asks nothing" do
      enable!(registration: :off)
      assert Gate.registration(context(client_ip()), nil) == :ok
      refute Gate.registration_preshow?(context(client_ip()))
    end
  end
end
