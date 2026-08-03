defmodule KilnCMS.Accounts.AccountThrottleTest do
  @moduledoc """
  Per-account auth budgets (#478) — the axis the per-IP `:auth` bucket can't
  cover, because an attacker rotating addresses gets a fresh window per address
  against the same account.

  Not `async: true`: the budgets live in one node-wide ETS table and these tests
  tighten the app-wide limits, so a concurrent suite signing in would see them.
  ExUnit runs sync modules after every async one, so the tightening can't reach
  another file.
  """
  use KilnCMS.DataCase, async: false

  import Phoenix.ConnTest
  import Swoosh.TestAssertions

  @endpoint KilnCMSWeb.Endpoint

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.User

  @password "password123456"
  @budget 3
  @mail_budget 2

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

  defp email, do: "throttle-#{System.unique_integer([:positive])}@example.com"

  defp user!(address) do
    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp sign_in(address, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => address,
      "password" => password
    })
  end

  defp exhaust(address) do
    for _ <- 1..@budget, do: sign_in(address, "wrong-password")
    :ok
  end

  describe "the sign-in budget" do
    test "a run of wrong passwords bounds further guesses, correct password included" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      assert {:ok, _user} = sign_in(address, @password)

      exhaust(address)

      # The point of a per-account budget: the *right* password is refused too,
      # or an attacker's final successful guess would still land.
      assert {:error, _} = sign_in(address, @password)
    end

    test "a successful sign-in forgives the attempts that came before it" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      # One short of the budget, then the real password.
      for _ <- 1..(@budget - 1), do: assert({:error, _} = sign_in(address, "wrong-password"))
      assert {:ok, _user} = sign_in(address, @password)

      # If the counter had survived, this run would spend the budget.
      for _ <- 1..(@budget - 1), do: assert({:error, _} = sign_in(address, "wrong-password"))
      assert {:ok, _user} = sign_in(address, @password)
    end

    test "a near miss followed by success does not mail the owner an attack alert" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..(@budget - 1), do: sign_in(address, "wrong-password")
      assert {:ok, _user} = sign_in(address, @password)
      drain_oban()

      # Counting the attempt is not the same event as refusing one. A user who
      # mistypes and then gets it right must not be told they are under attack —
      # and must not burn the once-per-window alert budget doing it.
      assert_no_email_sent()
    end

    test "an address with no account is refused identically, so it is not an oracle" do
      unknown = email()
      known = email()
      user!(known)
      on_exit(fn -> Enum.each([unknown, known], &AccountThrottle.reset/1) end)

      exhaust(unknown)
      exhaust(known)

      {:error, unknown_error} = sign_in(unknown, "anything")
      {:error, known_error} = sign_in(known, @password)

      assert Exception.message(unknown_error) == Exception.message(known_error)
    end

    test "the refusal is the same error, with the same message, a wrong password gives" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      {:error, wrong_password} = sign_in(address, "wrong-password")
      exhaust(address)
      {:error, throttled} = sign_in(address, @password)

      assert wrong_password.__struct__ == throttled.__struct__
      assert Exception.message(wrong_password) == Exception.message(throttled)
    end

    test "the identifier is normalized, so case and whitespace share one budget" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      exhaust(String.upcase(address))

      assert {:deny, _retry_after} = AccountThrottle.consume(address)
      assert {:deny, _retry_after} = AccountThrottle.consume("  #{address}  ")
    end

    test "the budget is spent atomically, so a simultaneous burst can't all pass" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      # A check followed by a separate increment would let every one of these
      # read "under budget" and proceed — the exact shape of a distributed
      # credential-stuffing burst. `consume/1` is one atomic operation.
      results =
        1..50
        |> Task.async_stream(fn _ -> AccountThrottle.consume(address) end, max_concurrency: 25)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :allow)) == @budget
    end

    test "the ETS table holds the digest, never the address" do
      address = email()
      on_exit(fn -> AccountThrottle.reset(address) end)

      AccountThrottle.consume(address)

      expected = "signin:" <> AccountThrottle.digest(address)

      keys =
        AccountThrottle |> :ets.tab2list() |> Enum.map(fn {{key, _window}, _c, _e} -> key end)

      assert expected in keys
      refute Enum.any?(keys, &String.contains?(&1, address))
    end
  end

  describe "proving ownership another way releases the budget" do
    test "completing a password reset forgives it" do
      address = email()
      user = user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      exhaust(address)
      assert {:error, _} = sign_in(address, @password)

      {:ok, reset_token} = reset_token(user)

      assert {:ok, _user} =
               user
               |> Ash.Changeset.for_update(
                 :reset_password_with_token,
                 %{
                   reset_token: reset_token,
                   password: "brand-new-password",
                   password_confirmation: "brand-new-password"
                 },
                 authorize?: false
               )
               |> Ash.update()

      # The alert mail tells the owner to reset their password; if the reset
      # left them locked out, that advice would be a dead end.
      assert :allow = AccountThrottle.consume(address)
    end
  end

  describe "the owner alert" do
    test "one mail when an attempt is first refused, and not again in the window" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      exhaust(address)
      assert {:error, _} = sign_in(address, "wrong-password")
      drain_oban()

      assert_email_sent(fn mail ->
        assert {_name, ^address} = hd(mail.to)
        assert mail.subject =~ "Unusual sign-in activity"
      end)

      # A sustained attack must not become a mail amplifier: further refusals
      # in the same window send nothing.
      for _ <- 1..5, do: sign_in(address, "wrong-password")
      drain_oban()
      assert_no_email_sent()
    end

    test "an address with no account is never mailed" do
      unknown = email()
      on_exit(fn -> AccountThrottle.reset(unknown) end)

      exhaust(unknown)
      sign_in(unknown, "anything")
      drain_oban()

      assert_no_email_sent()
    end

    test "an address that gains an account later still gets its first alert" do
      address = email()
      on_exit(fn -> AccountThrottle.reset(address) end)

      # Refused while nobody owns the address: the alert budget must survive,
      # or the real owner's first attack goes unreported.
      exhaust(address)
      sign_in(address, "anything")
      drain_oban()
      assert_no_email_sent()

      user!(address)
      sign_in(address, "anything")
      drain_oban()

      assert_email_sent(fn mail -> assert mail.subject =~ "Unusual sign-in activity" end)
    end
  end

  describe "mail-triggering requests" do
    test "each purpose gets its own per-address budget" do
      address = email()
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..@mail_budget, do: assert(AccountThrottle.allow_mail?(:password_reset, address))
      refute AccountThrottle.allow_mail?(:password_reset, address)

      # A reset flood must not silence magic links.
      assert AccountThrottle.allow_mail?(:magic_link, address)
    end

    test "a reset flood stops mailing the address it targets" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..@mail_budget, do: request_reset(address)
      drain_oban()

      for _ <- 1..@mail_budget,
          do: assert_email_sent(fn mail -> assert mail.subject =~ "Reset" end)

      request_reset(address)
      drain_oban()
      assert_no_email_sent()
    end

    test "a magic-link flood stops mailing the address it targets" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..@mail_budget, do: request_magic_link(address)
      drain_oban()

      for _ <- 1..@mail_budget,
          do: assert_email_sent(fn mail -> assert mail.subject =~ "sign-in link" end)

      request_magic_link(address)
      drain_oban()
      assert_no_email_sent()
    end
  end

  describe "the second-factor budget (#714)" do
    @second_factor_budget 2

    setup do
      previous = Application.get_env(:kiln_cms, AccountThrottle, [])

      Application.put_env(
        :kiln_cms,
        AccountThrottle,
        Keyword.put(previous, :second_factor_budget, @second_factor_budget)
      )

      on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
      :ok
    end

    test "is separate from the sign-in budget, so neither spends the other" do
      user_id = Ecto.UUID.generate()
      address = email()
      on_exit(fn -> AccountThrottle.reset(address) end)
      on_exit(fn -> AccountThrottle.forgive_second_factor(user_id) end)

      for _ <- 1..@second_factor_budget,
          do: assert(:allow = AccountThrottle.consume_second_factor(user_id))

      assert {:deny, _} = AccountThrottle.consume_second_factor(user_id)

      # The first factor is untouched: the two are different questions, and a
      # spent code budget must not also lock the password step (nor the reverse,
      # or every sign-in would eat into the codes an authenticator can be out of
      # sync by).
      assert :allow = AccountThrottle.consume(address)
    end

    test "is tighter than the sign-in budget, because six digits are guessable" do
      assert @second_factor_budget < @budget
    end

    test "a verified code clears it" do
      user_id = Ecto.UUID.generate()
      on_exit(fn -> AccountThrottle.forgive_second_factor(user_id) end)

      for _ <- 1..@second_factor_budget, do: AccountThrottle.consume_second_factor(user_id)
      assert {:deny, _} = AccountThrottle.consume_second_factor(user_id)

      AccountThrottle.forgive_second_factor(user_id)
      assert :allow = AccountThrottle.consume_second_factor(user_id)
    end
  end

  describe "the HTTP entry point" do
    test "the headless sign-in is throttled, not just the action" do
      address = email()
      user!(address)
      on_exit(fn -> AccountThrottle.reset(address) end)

      for _ <- 1..@budget, do: post_sign_in(address, "wrong-password")

      # The moduledoc claims the action-level hook covers every entry point;
      # asserting it only at the action layer would leave that claim untested.
      assert post_sign_in(address, @password).status == 401
    end
  end

  defp post_sign_in(address, password) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", %{"email" => address, "password" => password})
  end

  defp request_reset(address) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    AshAuthentication.Strategy.action(strategy, :reset_request, %{"email" => address})
  end

  defp request_magic_link(address) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    AshAuthentication.Strategy.action(strategy, :request, %{"email" => address})
  end

  defp reset_token(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
  end
end
