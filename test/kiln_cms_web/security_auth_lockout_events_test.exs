defmodule KilnCMSWeb.SecurityAuthLockoutEventsTest do
  @moduledoc """
  Lockouts in the security audit log (#2241): a spent sign-in budget, a spent
  second-factor budget (at the sign-in prompt and at the settings forms) and a
  spent per-address budget each write ONE `:sign_in_locked` event per window,
  with the scope in its metadata, and never name an account that does not exist.

  Not `async: true`: `Application.put_env` is global, and the shipped budgets
  are too large for a test to reach, so this file tightens `AccountThrottle`'s
  for its own tests (the test config raises them for every other file).
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Preparations.ThrottleSignIn
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Event
  alias KilnCMS.TwoFactorFixtures
  alias KilnCMSWeb.RateLimit

  @moduletag :capture_log

  @password "password123456"
  @ua "Mozilla/5.0 LockoutTest"

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous, budget: 3, second_factor_budget: 3)
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp seed_user do
    Ash.Seed.seed!(User, %{
      email: "lockout-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp locked(ip) do
    Event
    |> Ash.read!(authorize?: false, tenant: org_id())
    |> Enum.filter(&(&1.type == :sign_in_locked and &1.ip == ip))
  end

  defp unique_ip do
    n = uniq()
    "203.0.#{rem(n, 250)}.#{rem(div(n, 250), 250) + 1}"
  end

  defp ctx(ip) do
    %{security_request: %{ip: ip, user_agent: @ua}, security_tenant: org_id()}
  end

  defp sign_in(email, password, context) do
    AshAuthentication.Strategy.action(
      AshAuthentication.Info.strategy!(User, :password),
      :sign_in,
      %{"email" => email, "password" => password},
      context: context
    )
  end

  test "a spent sign-in budget is one event naming the account" do
    user = seed_user()
    ip = unique_ip()

    results = for _ <- 1..8, do: sign_in(to_string(user.email), "wrong", ctx(ip))
    assert Enum.all?(results, &match?({:error, _}, &1))

    assert [event] = locked(ip)
    assert event.actor_id == user.id
    assert event.actor_label == to_string(user.email)
    assert event.user_agent == @ua
    assert event.metadata == %{"method" => "password", "scope" => "account"}
  end

  test "a spent budget on an unknown address names nobody" do
    ip = unique_ip()
    email = "ghost-#{uniq()}@example.com"

    for _ <- 1..8, do: sign_in(email, "wrong", ctx(ip))

    assert [event] = locked(ip)
    assert event.actor_id == nil
    assert event.actor_label == nil
    refute inspect(event) =~ "ghost-"
  end

  test "a lockout is refused the same way for a known and an unknown address" do
    user = seed_user()
    for _ <- 1..4, do: sign_in(to_string(user.email), "wrong", ctx(unique_ip()))
    ghost = "ghost-#{uniq()}@example.com"
    for _ <- 1..4, do: sign_in(ghost, "wrong", ctx(unique_ip()))

    {:error, known} = sign_in(to_string(user.email), @password, ctx(unique_ip()))
    {:error, unknown} = sign_in(ghost, @password, ctx(unique_ip()))

    assert known.__struct__ == unknown.__struct__
  end

  test "a spent per-address budget is an address lockout and names no account" do
    user = seed_user()
    ip = unique_ip()
    {limit, _scale} = Map.fetch!(RateLimit.limits(), :auth)
    Enum.each(1..limit, fn _ -> RateLimit.check(:auth, ip) end)

    context = Map.merge(ctx(ip), ThrottleSignIn.client_ip_context(ip))
    assert {:error, _} = sign_in(to_string(user.email), @password, context)

    assert [event] = locked(ip)
    assert event.actor_id == nil
    assert event.metadata == %{"method" => "password", "scope" => "address"}
  end

  test "a spent second-factor budget is one event, scope second_factor" do
    {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
    ip = unique_ip()

    results = for _ <- 1..8, do: SecondFactor.check(user, "000000", context: ctx(ip))
    assert Enum.any?(results, &match?({:deny, _, _}, &1))

    assert [event] = locked(ip)
    assert event.actor_id == user.id
    assert event.metadata == %{"method" => "second_factor", "scope" => "second_factor"}
  end

  test "a spent budget at the settings forms is one event, scope settings" do
    {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
    ip = unique_ip()

    for _ <- 1..8 do
      Accounts.disable_totp(user, %{code: "000000"}, actor: user, context: ctx(ip))
    end

    assert [event] = locked(ip)
    assert event.actor_id == user.id
    assert event.metadata == %{"method" => "second_factor", "scope" => "settings"}
  end

  test "no org, no lockout event" do
    user = seed_user()
    ip = unique_ip()
    context = %{security_request: %{ip: ip, user_agent: @ua}}

    for _ <- 1..8, do: sign_in(to_string(user.email), "wrong", context)

    assert locked(ip) == []
  end
end
