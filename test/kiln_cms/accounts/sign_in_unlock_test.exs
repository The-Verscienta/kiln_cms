defmodule KilnCMS.Accounts.SignInUnlockTest do
  @moduledoc """
  The emailed link that lifts a sign-in pause (#2250), through the two system
  actions and `KilnCMS.Accounts.SignInUnlock`.

  `async: false`: every test lowers `AccountThrottle`'s budget with
  `Application.put_env/3` (the suite runs with a budget of a million, see
  `config/test.exs`), and some set the link's lifetime or turn challenges on,
  all node-wide.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures, only: [enable!: 0]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Accounts.Errors.SignInUnlockRefused
  alias KilnCMS.Accounts.SecondFactor
  alias KilnCMS.Accounts.SignInUnlock
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Accounts.User
  alias KilnCMS.Challenge
  alias KilnCMS.Security
  alias KilnCMS.Security.Recorder
  alias KilnCMS.TwoFactorFixtures

  @password "password123456"
  @budget 3
  @ip "203.0.113.77"

  setup do
    original = Application.get_env(:kiln_cms, AccountThrottle, [])
    original_unlock = Application.get_env(:kiln_cms, SignInUnlock, [])
    Application.put_env(:kiln_cms, AccountThrottle, Keyword.put(original, :budget, @budget))

    on_exit(fn ->
      Application.put_env(:kiln_cms, AccountThrottle, original)
      Application.put_env(:kiln_cms, SignInUnlock, original_unlock)
    end)

    :ok
  end

  defp email, do: "unlock-#{System.unique_integer([:positive])}@example.com"

  defp user!(address, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        attrs
      )
    )
  end

  defp pause!(address), do: Enum.each(1..@budget, fn _ -> AccountThrottle.consume(address) end)

  defp ctx(org_id \\ Accounts.default_org_id()) do
    %{Recorder.tenant_key() => org_id, Recorder.context_key() => %{ip: @ip, user_agent: nil}}
  end

  defp request(address, context \\ ctx()),
    do: Accounts.request_sign_in_unlock(address, authorize?: false, context: context)

  defp redeem(token, context \\ ctx()),
    do: Accounts.redeem_sign_in_unlock(token, authorize?: false, context: context)

  defp reason({:error, error}), do: SignInUnlockRefused.reason(error)

  # The token in the one unlock mail sent to `address`.
  defp mailed_token(address) do
    drain_oban()

    assert_email_sent(fn mail ->
      send(self(), {:body, mail.html_body})
      mail.to == [{"", address}] and mail.subject =~ "Lift the sign-in pause"
    end)

    assert_received {:body, body}
    [_, token] = Regex.run(~r{/auth/unlock/([A-Za-z0-9_.-]+)}, body)
    token
  end

  defp refute_mailed do
    drain_oban()
    refute_email_sent()
  end

  defp paused_with_link do
    address = email()
    user = user!(address)
    pause!(address)
    :ok = request(address)
    {user, address, mailed_token(address)}
  end

  defp sign_in(address, opts \\ []) do
    {token, opts} = Keyword.pop(opts, :challenge_token)
    params = %{"email" => address, "password" => @password}
    params = if token, do: Map.put(params, "challenge_token", token), else: params

    AshAuthentication.Strategy.action(
      AshAuthentication.Info.strategy!(User, :password),
      :sign_in,
      params,
      opts
    )
  end

  defp events(type, org_id \\ Accounts.default_org_id()) do
    [authorize?: false, tenant: org_id, page: [limit: 200]]
    |> Security.list_events!()
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  describe "the link's lifetime" do
    test "is fifteen minutes, read from the token's own claims" do
      user = user!(email())

      {:ok, _token, %{"exp" => exp, "iat" => iat}} =
        SignInUnlock.mint(user, Accounts.default_org_id())

      # AshAuthentication reads a bare integer lifetime as seconds; a value
      # passed in milliseconds would have been 10 days.
      assert exp - iat == 900
      assert SignInUnlock.ttl_seconds() == 900
      assert exp - iat <= div(AccountThrottle.defaults()[:window], 1000)
    end
  end

  describe "requesting a link" do
    test "mails a paused account a link, and redeeming it lifts the pause" do
      {_user, address, token} = paused_with_link()
      assert {:error, _} = sign_in(address)

      assert :ok = redeem(token)

      assert AccountThrottle.sign_in_attempts(address) == 0
      assert {:ok, %User{}} = sign_in(address)
    end

    test "the mail names the site, the link and its limits, and nothing from the request" do
      address = email()
      user!(address)
      pause!(address)
      :ok = request(address)
      drain_oban()

      assert_email_sent(fn mail ->
        assert mail.subject =~ "Lift the sign-in pause on your"
        assert mail.html_body =~ "/auth/unlock/"
        assert mail.html_body =~ "works once, within 15 minutes"
        assert mail.html_body =~ "does not sign you in"
        assert mail.html_body =~ "/reset"
        refute mail.html_body =~ @ip
        true
      end)
    end

    test "sends nothing for an unknown, unpaused, unconfirmed, anonymized or demo account" do
      unknown = email()
      pause!(unknown)

      unpaused = email()
      user!(unpaused)

      unconfirmed = email()
      user!(unconfirmed, %{confirmed_at: nil})
      pause!(unconfirmed)

      anonymized = email()
      user!(anonymized, %{anonymized_at: DateTime.utc_now()})
      pause!(anonymized)

      for address <- [unknown, unpaused, unconfirmed, anonymized], do: :ok = request(address)
      refute_mailed()

      # An address that is never mailed writes no mail-budget row (R12).
      for address <- [unknown, unpaused, unconfirmed, anonymized] do
        assert ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)) == 0
      end
    end

    test "sends nothing to the demo's shared account" do
      original = Application.get_env(:kiln_cms, KilnCMS.Demo, [])
      Application.put_env(:kiln_cms, KilnCMS.Demo, Keyword.put(original, :enabled, true))
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Demo, original) end)

      address = email()
      user!(address, %{role: :viewer})
      pause!(address)

      :ok = request(address)
      refute_mailed()
    end

    test "is budgeted at three mails an hour per address" do
      address = email()
      user!(address)
      pause!(address)

      for _ <- 1..4, do: :ok = request(address)
      drain_oban()

      for _ <- 1..3 do
        assert_email_sent(fn mail -> mail.to == [{"", address}] end)
      end

      refute_email_sent()
      assert AccountThrottle.defaults()[:unlock_mail_budget] == 3
    end

    test "sends nothing, records nothing and spends nothing for a non-member of the site" do
      site = KilnCMS.OrgFixtures.org("unlock-stranger")
      address = email()
      user!(address)
      pause!(address)

      assert :ok = request(address, ctx(site.id))
      refute_mailed()
      assert events(:sign_in_unlock_requested, site.id) == []
      assert ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)) == 0
    end

    test "mails a member of a non-default site, from that site" do
      site = KilnCMS.OrgFixtures.org("unlock-member")
      address = email()
      user = user!(address)
      pause!(address)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: site.id,
        user_id: user.id,
        role: :editor
      })

      assert :ok = request(address, ctx(site.id))
      token = mailed_token(address)
      assert [_requested] = events(:sign_in_unlock_requested, site.id)

      assert :ok = redeem(token, ctx(site.id))
      refute AccountThrottle.sign_in_paused?(address)
    end

    test "spends no mail budget when the site no longer exists" do
      address = email()
      user!(address)
      pause!(address)

      # A legacy (no-membership) account belongs only to the default site, so a
      # vanished site fails the membership rule before the org lookup; either
      # way nothing is charged.
      assert :ok = request(address, ctx(Ecto.UUID.generate()))
      refute_mailed()
      assert ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)) == 0
    end

    test "answers :ok without a site, and mails nothing" do
      address = email()
      user!(address)
      pause!(address)

      assert :ok = request(address, %{})
      refute_mailed()
    end
  end

  describe "redeeming a link" do
    test "clears the sign-in counter and nothing else" do
      {user, address, token} = paused_with_link()

      AccountThrottle.spend_free_attempt(address, 1)
      AccountThrottle.spend_free_attempt(address, 1)
      AccountThrottle.consume_second_factor(user.id)
      AccountThrottle.alert_allowed?(address)
      KilnCMSWeb.RateLimit.check(:auth, @ip)

      before = %{
        free: ThrottleStore.spent("challenge:free_signin", AccountThrottle.digest(address)),
        second_factor: ThrottleStore.spent("2fa", AccountThrottle.digest(user.id)),
        alert: ThrottleStore.spent("signin:alert", AccountThrottle.digest(address)),
        mail: ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)),
        ip: ThrottleStore.spent("ip:auth", @ip)
      }

      assert Enum.all?(Map.values(before), &(&1 > 0))

      assert :ok = redeem(token)

      assert ThrottleStore.spent("signin", AccountThrottle.digest(address)) == 0

      assert %{
               free:
                 ThrottleStore.spent("challenge:free_signin", AccountThrottle.digest(address)),
               second_factor: ThrottleStore.spent("2fa", AccountThrottle.digest(user.id)),
               alert: ThrottleStore.spent("signin:alert", AccountThrottle.digest(address)),
               mail: ThrottleStore.spent("mail:sign_in_unlock", AccountThrottle.digest(address)),
               ip: ThrottleStore.spent("ip:auth", @ip)
             } == before
    end

    test "works once" do
      {_user, _address, token} = paused_with_link()

      assert :ok = redeem(token)
      assert reason(redeem(token)) == :used
    end

    test "two simultaneous redeems: exactly one succeeds" do
      {_user, _address, token} = paused_with_link()
      parent = self()

      results =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> redeem(token)
            end
          end)
        end)
        |> tap(fn tasks ->
          for _ <- tasks, do: assert_receive({:ready, _})
          for task <- tasks, do: send(task.pid, :go)
        end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert [refused] = Enum.reject(results, &(&1 == :ok))
      assert reason(refused) == :used
    end

    test "is refused once expired" do
      # The shortest lifetime a JWT can carry: `exp` is whole seconds.
      Application.put_env(
        :kiln_cms,
        SignInUnlock,
        Keyword.put(Application.get_env(:kiln_cms, SignInUnlock, []), :ttl, 1)
      )

      {_user, _address, token} = paused_with_link()
      Process.sleep(2_100)

      assert reason(redeem(token)) == :expired
    end

    test "is revoked by a password change" do
      {user, _address, token} = paused_with_link()

      assert {:ok, _} =
               user
               |> Ash.Changeset.for_update(
                 :change_password,
                 %{
                   current_password: @password,
                   password: "brand-new-password-789",
                   password_confirmation: "brand-new-password-789"
                 },
                 actor: user
               )
               |> Ash.update()

      assert reason(redeem(token)) == :used
    end

    test "is revoked by a password reset" do
      {user, _address, token} = paused_with_link()
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, reset_token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

      assert {:ok, _} =
               AshAuthentication.Strategy.action(
                 strategy,
                 :reset,
                 %{
                   "reset_token" => reset_token,
                   "password" => "brand-new-password-789",
                   "password_confirmation" => "brand-new-password-789"
                 },
                 []
               )

      assert reason(redeem(token)) == :used
    end

    test "is refused once the address has changed" do
      {user, address, token} = paused_with_link()
      Ash.Seed.update!(user, %{email: "changed-" <> address})

      assert reason(redeem(token)) == :account_changed
    end

    test "is refused once the account is erased" do
      {user, _address, token} = paused_with_link()
      Ash.Seed.update!(user, %{anonymized_at: DateTime.utc_now()})

      assert reason(redeem(token)) == :account_changed
    end

    test "on another site is refused without being spent" do
      other = KilnCMS.OrgFixtures.org("unlock-other")
      {_user, address, token} = paused_with_link()

      assert reason(redeem(token, ctx(other.id))) == :wrong_site
      assert AccountThrottle.sign_in_paused?(address)

      assert :ok = redeem(token)
      refute AccountThrottle.sign_in_paused?(address)
    end

    test "a made-up, malformed or foreign token is :invalid" do
      user = user!(email())
      {:ok, session_token, _} = AshAuthentication.Jwt.token_for_user(user)

      for token <- ["not-a-jwt", "a.b.c", session_token] do
        assert reason(redeem(token)) == :invalid
      end

      # An empty token never reaches the check: the argument is required.
      assert {:error, %Ash.Error.Invalid{}} = redeem("")
    end
  end

  describe "the link is no other credential" do
    test "it is not a bearer token" do
      {_user, _address, token} = paused_with_link()
      assert KilnCMSWeb.BearerAuth.user_from_token(token) == :error
    end

    test "the reset, confirmation, magic-link and token sign-in routes refuse it" do
      {_user, _address, token} = paused_with_link()
      password = AshAuthentication.Info.strategy!(User, :password)
      magic_link = AshAuthentication.Info.strategy!(User, :magic_link)
      confirm = AshAuthentication.Info.strategy!(User, :confirm_new_user)

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 password,
                 :reset,
                 %{
                   "reset_token" => token,
                   "password" => "brand-new-password-789",
                   "password_confirmation" => "brand-new-password-789"
                 },
                 []
               )

      assert {:error, _} =
               AshAuthentication.Strategy.action(
                 password,
                 :sign_in_with_token,
                 %{"token" => token},
                 []
               )

      assert {:error, _} =
               AshAuthentication.Strategy.action(magic_link, :sign_in, %{"token" => token}, [])

      assert {:error, _} =
               AshAuthentication.Strategy.action(confirm, :confirm, %{"confirm" => token}, [])

      # And none of them spent it.
      assert :ok = redeem(token)
    end
  end

  describe "signing in after an unlock" do
    test "with challenges off, the password is admitted" do
      {_user, address, token} = paused_with_link()
      assert {:error, _} = sign_in(address)

      assert :ok = redeem(token)
      assert {:ok, %User{}} = sign_in(address)
    end

    test "with adaptive challenges, a challenge is still asked for and then admits" do
      enable!()
      {_user, address, token} = paused_with_link()
      # The paused account has also spent its free attempts before a challenge.
      for _ <- 1..Challenge.threshold(:account),
          do: AccountThrottle.spend_free_attempt(address, Challenge.threshold(:account))

      assert :ok = redeem(token)

      context =
        Map.merge(%{security_request: %{ip: @ip, user_agent: nil}}, Challenge.context(:browser))

      assert {:error, error} = sign_in(address, context: context)
      assert %ChallengeRequired{} = ChallengeRequired.find(error)

      assert {:ok, %User{}} = sign_in(address, context: context, challenge_token: "pass")
    end

    test "a 2FA account whose code budget is spent still has its code refused" do
      {user, secret} = TwoFactorFixtures.enabled_user()
      address = to_string(user.email)
      pause!(address)

      for _ <- 1..AccountThrottle.defaults()[:second_factor_budget],
          do: AccountThrottle.consume_second_factor(user.id)

      on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

      original = Application.get_env(:kiln_cms, AccountThrottle, [])

      Application.put_env(
        :kiln_cms,
        AccountThrottle,
        Keyword.put(
          original,
          :second_factor_budget,
          AccountThrottle.defaults()[:second_factor_budget]
        )
      )

      :ok = request(address)
      assert :ok = redeem(mailed_token(address))

      # The password step is admitted again ...
      assert {:ok, _} =
               AshAuthentication.Strategy.action(
                 AshAuthentication.Info.strategy!(User, :password),
                 :sign_in,
                 %{"email" => address, "password" => TwoFactorFixtures.password()},
                 []
               )

      # ... and the second factor's own budget is untouched by the unlock.
      assert {:deny, _user, _retry} =
               SecondFactor.check(user, TwoFactorFixtures.current_code(secret))
    end
  end

  describe "refused actors" do
    test "an authorized call is forbidden to everyone, admins included" do
      {_user, address, token} = paused_with_link()
      admin = user!(email(), %{role: :admin})
      viewer = user!(email(), %{role: :viewer})

      for actor <- [nil, viewer, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.request_sign_in_unlock(address, actor: actor, context: ctx())

        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.redeem_sign_in_unlock(token, actor: actor, context: ctx())
      end

      refute_mailed()
      assert AccountThrottle.sign_in_paused?(address)
    end

    test "a system call that carries an actor is refused too" do
      {_user, address, token} = paused_with_link()
      admin = user!(email(), %{role: :admin})

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.request_sign_in_unlock(address,
                 actor: admin,
                 authorize?: false,
                 context: ctx()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.redeem_sign_in_unlock(token,
                 actor: admin,
                 authorize?: false,
                 context: ctx()
               )

      refute_mailed()
      assert AccountThrottle.sign_in_paused?(address)
    end
  end

  describe "the security log" do
    test "records a mailed link and a lifted pause, labelled for a member" do
      {user, _address, token} = paused_with_link()
      assert :ok = redeem(token)

      assert [requested] = events(:sign_in_unlock_requested)
      assert requested.actor_id == user.id
      assert requested.metadata == %{"surface" => "browser"}
      assert requested.ip == @ip

      assert [unlocked] = events(:sign_in_unlocked)
      assert unlocked.actor_id == user.id
      assert unlocked.metadata == %{"was_locked" => "true"}
    end

    test "records nothing for a request that mails nothing" do
      :ok = request(email())
      assert events(:sign_in_unlock_requested) == []
    end

    test "records a refusal with its reason, and no actor for a forged token" do
      {user, _address, token} = paused_with_link()
      assert :ok = redeem(token)
      assert {:error, _} = redeem(token)
      assert {:error, _} = redeem("not-a-jwt")

      refusals = events(:sign_in_unlock_refused)
      assert Enum.map(refusals, & &1.metadata["reason"]) |> Enum.sort() == ["invalid", "used"]
      assert Enum.find(refusals, &(&1.metadata["reason"] == "used")).actor_id == user.id
      assert Enum.find(refusals, &(&1.metadata["reason"] == "invalid")).actor_id == nil
    end

    test "a refusal on another site names no account that is not its member" do
      other = KilnCMS.OrgFixtures.org("unlock-log")
      {_user, _address, token} = paused_with_link()
      assert {:error, _} = redeem(token, ctx(other.id))

      assert [refused] = events(:sign_in_unlock_refused, other.id)
      assert refused.metadata == %{"reason" => "wrong_site"}
      assert refused.actor_id == nil
      assert events(:sign_in_unlock_refused) == []
    end
  end
end
