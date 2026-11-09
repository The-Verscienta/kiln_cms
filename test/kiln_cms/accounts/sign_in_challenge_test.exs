defmodule KilnCMS.Accounts.SignInChallengeTest do
  @moduledoc """
  Human verification on the `:sign_in_with_password` and
  `:register_with_password` actions themselves (#2249) — the one place every
  door passes.

  The refusals come first, because they carry the guarantees: a sign-in
  refused for want of a challenge spends nothing of the account's budget and
  no bcrypt; a known and an unknown address are refused alike; and the
  failure counter behind the address axis counts credential failures only.

  `async: false`: `KilnCMS.ChallengeFixtures.enable!/1` writes node-wide config.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures
  import KilnCMS.EnumerationAssertions
  import KilnCMS.RateLimitHelpers, only: [client_ip: 0]

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Accounts.User
  alias KilnCMS.Challenge

  @password "password123456"

  defp email, do: "challenge-#{System.unique_integer([:positive])}@example.com"

  defp user!(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp context(ip, surface \\ :browser) do
    Map.merge(
      %{security_request: %{ip: ip, user_agent: nil}},
      Challenge.context(surface)
    )
  end

  defp sign_in(address, password, opts) do
    {token, opts} = Keyword.pop(opts, :token)
    params = %{"email" => address, "password" => password}
    params = if token, do: Map.put(params, "challenge_token", token), else: params

    AshAuthentication.Strategy.action(
      AshAuthentication.Info.strategy!(User, :password),
      :sign_in,
      params,
      opts
    )
  end

  # Earlier attempts on `address`: each one spent of the account's budget and of
  # its free attempts before a challenge, as an admitted sign-in does.
  defp attempts(address, n) do
    Enum.each(1..n//1, fn _ ->
      AccountThrottle.consume(address)
      AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))
    end)
  end

  defp ip_failures(ip),
    do: ThrottleStore.peek("challenge:signin_ip", ip, Challenge.threshold(:ip_window))

  defp refusal({:error, reason}), do: ChallengeRequired.find(reason)
  defp refusal(_ok), do: nil

  # What a caller can observe of a refusal: its reason and its message (the
  # struct also carries a stacktrace, which differs between any two calls).
  defp seen(result) do
    case refusal(result) do
      %ChallengeRequired{reason: reason} = error -> {reason, Exception.message(error)}
      nil -> result
    end
  end

  setup do
    enable!()
    :ok
  end

  describe "a refused sign-in" do
    test "without a token spends nothing of the account's budget" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      before = AccountThrottle.sign_in_attempts(address)

      for _ <- 1..5 do
        result = sign_in(address, @password, context: context(client_ip()))
        assert %ChallengeRequired{reason: :required} = refusal(result)
      end

      assert AccountThrottle.sign_in_attempts(address) == before
    end

    test "with a refused token spends nothing either, and is :failed" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      before = AccountThrottle.sign_in_attempts(address)

      result = sign_in(address, @password, token: "fail", context: context(client_ip()))
      assert %ChallengeRequired{reason: :failed} = refusal(result)
      assert AccountThrottle.sign_in_attempts(address) == before
    end

    test "pays no bcrypt" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))

      {result, counts} =
        count_calls(
          fn -> sign_in(address, @password, context: context(client_ip())) end,
          [{Bcrypt, :verify_pass, 2}, {Bcrypt, :no_user_verify, 1}]
        )

      assert %ChallengeRequired{} = refusal(result)
      assert counts[{Bcrypt, :verify_pass, 2}] == 0
      assert counts[{Bcrypt, :no_user_verify, 1}] == 0
    end

    test "is the same for a known and an unknown address" do
      known = email()
      unknown = email()
      user!(known)
      attempts(known, Challenge.threshold(:account))
      attempts(unknown, Challenge.threshold(:account))

      assert_indistinguishable(
        fn -> seen(sign_in(known, "wrong-password", context: context(client_ip()))) end,
        fn -> seen(sign_in(unknown, "wrong-password", context: context(client_ip()))) end,
        [known, unknown]
      )

      assert_indistinguishable(
        fn ->
          seen(sign_in(known, "wrong-password", token: "fail", context: context(client_ip())))
        end,
        fn ->
          seen(sign_in(unknown, "wrong-password", token: "fail", context: context(client_ip())))
        end,
        [known, unknown]
      )
    end

    test "is not counted as a failure against the client address" do
      address = email()
      ip = client_ip()
      attempts(address, Challenge.threshold(:account))

      sign_in(address, "wrong-password", context: context(ip))
      sign_in(address, "wrong-password", token: "fail", context: context(ip))

      assert ip_failures(ip) == 0
    end

    test "records challenge_failed in the audit log, and a bare ask records nothing" do
      org = KilnCMS.OrgFixtures.org("challenge-audit")
      address = email()
      attempts(address, Challenge.threshold(:account))

      ctx = Map.put(context(client_ip()), KilnCMS.Security.Recorder.tenant_key(), org.id)

      sign_in(address, @password, context: ctx)
      assert reasons(org.id) == []

      sign_in(address, @password, token: "fail", context: ctx)
      assert reasons(org.id) == ["challenge_failed"]
    end
  end

  describe "an admitted sign-in" do
    test "with a passing token reaches the password and signs in" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))

      assert {:ok, %User{}} =
               sign_in(address, @password, token: "pass", context: context(client_ip()))

      # The success forgave the account's counter, as any completed sign-in does.
      assert AccountThrottle.sign_in_attempts(address) == 0
    end

    test "with a passing token and a wrong password charges the account" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))
      before = AccountThrottle.sign_in_attempts(address)

      assert {:error, _} =
               sign_in(address, "wrong-password", token: "pass", context: context(client_ip()))

      assert AccountThrottle.sign_in_attempts(address) == before + 1
    end

    test "below every threshold needs no token at all" do
      address = email()
      user!(address)

      assert {:ok, %User{}} = sign_in(address, @password, context: context(client_ip()))
      refute_received {:challenge_verify, _, _}
    end
  end

  describe "the client-address axis" do
    test "counts credential failures, never a success, and is not forgiven by one" do
      address = email()
      user!(address)
      ip = client_ip()

      sign_in(address, "wrong-password", context: context(ip))
      sign_in(email(), "wrong-password", context: context(ip))
      assert ip_failures(ip) == 2

      assert {:ok, _} = sign_in(address, @password, context: context(ip))
      assert ip_failures(ip) == 2
    end

    test "successful sign-ins from one address never add up to a challenge" do
      ip = client_ip()
      address = email()
      user!(address)

      for _ <- 1..(Challenge.threshold(:ip) * 3) do
        assert {:ok, _} = sign_in(address, @password, context: context(ip))
      end

      sign_in(email(), "wrong", context: context(ip))
      assert {:ok, _} = sign_in(address, @password, context: context(ip))
    end

    test "past its threshold asks every address's sign-in from there" do
      ip = client_ip()

      for _ <- 1..Challenge.threshold(:ip), do: sign_in(email(), "wrong", context: context(ip))

      address = email()
      user!(address)

      assert %ChallengeRequired{reason: :required} =
               refusal(sign_in(address, @password, context: context(ip)))

      assert {:ok, _} = sign_in(address, @password, token: "pass", context: context(ip))
    end

    test "reads the address from the security context, not from the LiveView's key" do
      ip = client_ip()
      for _ <- 1..Challenge.threshold(:ip), do: sign_in(email(), "wrong", context: context(ip))

      address = email()
      user!(address)

      # The same address, but only under the key `ThrottleSignIn` charges the
      # `:auth` bucket on: no security context, so no address axis.
      only_live_key =
        Map.merge(
          KilnCMS.Accounts.Preparations.ThrottleSignIn.client_ip_context(ip),
          Challenge.context(:browser)
        )

      assert {:ok, _} = sign_in(address, @password, context: only_live_key)
    end
  end

  describe "while the provider cannot be asked" do
    test "fails open until the account's own budget refuses" do
      original = Application.get_env(:kiln_cms, AccountThrottle)
      Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(original, :budget, 5))
      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, original) end)

      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))

      results =
        for _ <- 1..4,
            do: sign_in(address, "wrong-password", token: "down", context: context(client_ip()))

      # Admitted to the password (and charged) while the budget lasts, then
      # refused by the budget itself — never waved through past it.
      assert Enum.all?(results, &match?({:error, _}, &1))
      assert Enum.all?(results, &(refusal(&1) == nil))
      assert AccountThrottle.sign_in_attempts(address) == 3 + 4

      assert {:error, _} =
               sign_in(address, @password, token: "down", context: context(client_ip()))
    end

    test "fails closed from an address past ip_closed_after" do
      ip = client_ip()

      # A passing token past the threshold, so every one of these reaches the
      # password and counts.
      for _ <- 1..Challenge.threshold(:ip_closed_after),
          do: sign_in(email(), "wrong", token: "pass", context: context(ip))

      assert ip_failures(ip) == Challenge.threshold(:ip_closed_after)

      address = email()
      user!(address)

      assert %ChallengeRequired{reason: :unavailable} =
               refusal(sign_in(address, @password, token: "down", context: context(ip)))
    end
  end

  describe "the headless door" do
    test "is untouched while api_sign_in is off" do
      address = email()
      user!(address)
      attempts(address, Challenge.threshold(:account))

      assert {:ok, _} = sign_in(address, @password, context: context(client_ip(), :api))
      refute_received {:challenge_verify, _, _}
    end
  end

  describe "a registration" do
    defp register(address, opts) do
      {token, opts} = Keyword.pop(opts, :token)

      params = %{
        "email" => address,
        "password" => @password,
        "password_confirmation" => @password
      }

      params = if token, do: Map.put(params, "challenge_token", token), else: params

      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :register,
        params,
        opts
      )
    end

    test "under :always is refused without a passing token, and creates nothing" do
      enable!(registration: :always)
      address = email()

      assert %ChallengeRequired{reason: :required} =
               refusal(register(address, context: context(client_ip())))

      assert %ChallengeRequired{reason: :failed} =
               refusal(register(address, token: "fail", context: context(client_ip())))

      assert {:ok, nil} =
               KilnCMS.Accounts.get_user_by_email(address,
                 authorize?: false,
                 not_found_error?: false
               )

      assert {:ok, %User{}} = register(address, token: "pass", context: context(client_ip()))
    end

    test "is refused alike for an address that has an account and one that has not" do
      enable!(registration: :always)
      known = email()
      unknown = email()
      user!(known)

      assert_indistinguishable(
        fn -> seen(register(known, context: context(client_ip()))) end,
        fn -> seen(register(unknown, context: context(client_ip()))) end,
        [known, unknown]
      )
    end
  end

  defp reasons(org_id) do
    admin =
      Ash.Seed.seed!(User, %{
        email: email(),
        hashed_password: "x",
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    [actor: admin, tenant: org_id, page: [limit: 50]]
    |> KilnCMS.Security.list_events!()
    |> then(fn
      %{results: results} -> results
      results when is_list(results) -> results
    end)
    |> Enum.filter(&(&1.type == :sign_in_failed))
    |> Enum.map(& &1.metadata["reason"])
  end
end
