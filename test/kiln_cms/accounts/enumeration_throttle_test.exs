defmodule KilnCMS.Accounts.EnumerationThrottleTest do
  @moduledoc """
  A spent budget does not turn into an oracle (#2255).

  The per-account sign-in budget and the per-address mail budget are keyed on
  the *string* a caller typed, whether or not an account answers to it, so a
  known and an unknown address must run out at the same point and be refused in
  the same words — compared whole by `KilnCMS.EnumerationAssertions`.

  `async: false`: it tightens the node-wide `AccountThrottle` config with
  `Application.put_env`, which every other test would otherwise inherit.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.EnumerationAssertions
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User

  @password "password123456"
  @budget 2
  @mail_budget 1

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        budget: @budget,
        window: :timer.minutes(15),
        mail_budget: @mail_budget,
        mail_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp address(tag), do: "#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp seed_user(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp api_sign_in(address, password) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/auth/sign_in", %{"email" => address, "password" => password})
  end

  defp sign_in_action(address, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(
      strategy,
      :sign_in,
      %{"email" => address, "password" => password},
      []
    )
  end

  describe "the per-account sign-in budget" do
    test "refuses a known and an unknown address with the same 401" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)
      on_exit(fn -> Enum.each([known, unknown], &AccountThrottle.reset/1) end)

      for who <- [known, unknown], _ <- 1..@budget, do: api_sign_in(who, "wrong-password")

      # Past the budget even the CORRECT password is refused for the known
      # account, so the two sides differ in what a success would have been —
      # and still must not differ in what they say.
      seen =
        assert_indistinguishable(
          fn -> api_sign_in(known, @password) end,
          fn -> api_sign_in(unknown, @password) end,
          [known, unknown]
        )

      assert seen.status == 401
    end

    test "costs one dummy bcrypt check on each side, so neither answers faster" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)
      on_exit(fn -> Enum.each([known, unknown], &AccountThrottle.reset/1) end)

      for who <- [known, unknown], _ <- 1..@budget, do: sign_in_action(who, "wrong-password")

      counted = [{Bcrypt, :verify_pass, 2}, {Bcrypt, :no_user_verify, 1}]

      {{:error, known_error}, on_known} =
        count_calls(fn -> sign_in_action(known, @password) end, counted)

      {{:error, unknown_error}, on_unknown} =
        count_calls(fn -> sign_in_action(unknown, @password) end, counted)

      assert on_known == on_unknown
      assert on_known[{Bcrypt, :no_user_verify, 1}] == 1
      assert on_known[{Bcrypt, :verify_pass, 2}] == 0
      assert Exception.message(known_error) == Exception.message(unknown_error)
    end
  end

  describe "the per-address mail budget" do
    defp request(strategy_name, action, address) do
      strategy = AshAuthentication.Info.strategy!(User, strategy_name)
      AshAuthentication.Strategy.action(strategy, action, %{"email" => address}, [])
    end

    test "a reset request past the budget still answers :ok, as for an unknown address" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)

      on_exit(fn ->
        Enum.each([known, unknown], &AccountThrottle.reset/1)
      end)

      # Spend the single mail the budget allows for each address.
      assert :ok = request(:password, :reset_request, known)
      assert :ok = request(:password, :reset_request, unknown)

      assert_indistinguishable(
        fn -> request(:password, :reset_request, known) end,
        fn -> request(:password, :reset_request, unknown) end,
        [known, unknown]
      )

      KilnCMS.DataCase.drain_oban()

      # One mail to the owner (the first request) and nothing for the second:
      # the throttle is silent, exactly as a miss is.
      assert_email_sent(fn email -> email.to == [{"", known}] end)
      refute_email_sent()
    end

    test "a magic link request past the budget still answers :ok, as for an unknown address" do
      known = address("known")
      unknown = address("unknown")
      seed_user(known)
      on_exit(fn -> Enum.each([known, unknown], &AccountThrottle.reset/1) end)

      assert :ok = request(:magic_link, :request, known)
      assert :ok = request(:magic_link, :request, unknown)

      assert_indistinguishable(
        fn -> request(:magic_link, :request, known) end,
        fn -> request(:magic_link, :request, unknown) end,
        [known, unknown]
      )

      KilnCMS.DataCase.drain_oban()

      assert_email_sent(fn email -> email.to == [{"", known}] end)
      refute_email_sent()
    end
  end
end
