defmodule KilnCMS.Accounts.SecondFactorAlertTest do
  @moduledoc """
  The owner alert on a second-factor lockout (#728).

  #478 mails an owner when their *password* is being guessed at. #714 added the
  equivalent budget for the *second factor* and mailed nobody — which is
  backwards on signal strength, because reaching that prompt requires a signed
  pending token and that token is only minted once a first factor has already
  succeeded.

  The password alert could not cover the case either: to keep grinding, an
  attacker keeps minting pending tokens, which means re-running the first
  factor — and that step succeeds, so `ThrottleSignIn` forgave the sign-in
  counter every time and its budget was never reached. #742 closed that reset,
  so both alerts can now fire on the same attack; this one still rings first,
  because the second-factor budget is the tighter of the two.
  `KilnCMS.Accounts.SignInCounterTest` owns the counter behaviour itself.

  A third of these tests are about what the mail may **not** say. "Someone has
  your password" is the obvious sentence and it is wrong twice: the first factor
  may have been a magic link or an SSO assertion, and since #727 the budget is
  shared with the settings forms, so the likeliest trigger is the owner
  themselves. Both are pinned below, because the failure mode of a security mail
  that names the wrong compromise is an owner securing the wrong account.

  `async: false`: node-wide ETS budgets, tightened app-wide via `put_env`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.DataCase, only: [drain_oban: 0]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.TwoFactorFixtures

  @password "password123456"
  @budget 2
  @subject "Two-factor sign-in blocked"
  @password_alert_subject "Unusual sign-in activity"

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        second_factor_budget: @budget,
        # Widened, not tightened — a fixed-window rollover mid-test is the #697
        # flake shape.
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
    :ok
  end

  defp enabled_user, do: TwoFactorFixtures.enabled_user(role: :editor)

  # The state a browser is in after the first factor and before the second.
  # A real, stored first-factor JWT rather than a stub (#1171): `mint_and_hold/4`
  # holds the stored row, and a stub has none — the "nothing to hold" branch is
  # silent, so a stub here would exercise a path no sign-in ever takes.
  defp with_pending(user) do
    {user, _token} = TwoFactorFixtures.with_first_factor_token(user)
    token = PendingSignIn.mint_and_hold(:session, KilnCMSWeb.Endpoint, user)

    build_conn()
    |> unique_ip()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:pending_2fa, token)
  end

  defp browser_verify(user, code),
    do: post(with_pending(user), ~p"/sign-in/verify", %{"code" => code})

  defp headless_pending(user) do
    conn =
      build_conn()
      |> unique_ip()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth/sign_in", %{email: to_string(user.email), password: @password})

    json_response(conn, 200)["pending_token"]
  end

  defp headless_verify(pending, code) do
    build_conn()
    |> unique_ip()
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/auth/sign_in/verify", %{pending_token: pending, code: code})
  end

  defp exhaust(user), do: Enum.each(1..@budget, fn _ -> browser_verify(user, "000000") end)

  defp cleanup(user) do
    on_exit(fn ->
      AccountThrottle.forgive_second_factor(user.id)
      AccountThrottle.forget_second_factor_alert(user.id)
      AccountThrottle.reset(to_string(user.email))
    end)
  end

  describe "the browser prompt" do
    test "a lockout mails the owner" do
      {user, _secret} = enabled_user()
      cleanup(user)

      exhaust(user)
      assert browser_verify(user, "000000").status == 429
      drain_oban()

      assert_email_sent(fn mail ->
        assert {_name, address} = hd(mail.to)
        assert address == to_string(user.email)
        assert mail.subject =~ @subject

        # The copy is the point of the issue, not a detail.
        #
        # It must not repeat the password alert's "your password has not been
        # used successfully" — the one thing that cannot be said here. It must
        # also not assert the opposite: the first factor may have been a magic
        # link or an SSO assertion (`AuthController.success/4` is the callback
        # for every strategy), and since #727 the budget is shared with the
        # settings forms, so the likeliest trigger of all is the owner
        # themselves. It states what is known and offers the rest as a
        # checklist.
        refute mail.html_body =~ "has not been used successfully"
        refute mail.html_body =~ "someone has your password"
        assert mail.html_body =~ "completed the first step of signing in"
        assert mail.html_body =~ "If that was you"
        assert mail.html_body =~ "single sign-on"
        assert mail.html_body =~ "recovery codes"
      end)
    end

    test "a correct code that is refused by the budget still alerts" do
      # A legitimate user typing their real code into a spent budget also gets
      # the mail. That is deliberate — the budget was spent by *someone*, and if
      # it was not them, this is the only warning they get.
      {user, secret} = enabled_user()
      cleanup(user)

      exhaust(user)
      code = TwoFactorFixtures.current_code(secret)
      assert browser_verify(user, code).status == 429
      drain_oban()

      assert_email_sent(fn mail -> assert mail.subject =~ @subject end)
    end

    test "a sustained grind produces one mail, not one per refusal" do
      {user, _secret} = enabled_user()
      cleanup(user)

      exhaust(user)
      browser_verify(user, "000000")
      drain_oban()
      assert_email_sent(fn mail -> assert mail.subject =~ @subject end)

      for _ <- 1..8, do: browser_verify(user, "000000")
      drain_oban()
      assert_no_email_sent()
    end

    test "a wrong code inside the budget mails nothing" do
      {user, _secret} = enabled_user()
      cleanup(user)

      assert browser_verify(user, "000000").status == 401
      drain_oban()

      assert_no_email_sent()
    end
  end

  describe "the headless gate" do
    test "a lockout there mails the same owner the same news" do
      # Wiring only the browser prompt would leave an attacker a door that
      # alerts nobody — #726's own lesson, one layer up.
      {user, _secret} = enabled_user()
      cleanup(user)

      pending = headless_pending(user)
      Enum.each(1..@budget, fn _ -> headless_verify(pending, "000000") end)

      assert headless_verify(pending, "000000").status == 429
      drain_oban()

      assert_email_sent(fn mail -> assert mail.subject =~ @subject end)
    end

    test "the two doors share the alert budget, so alternating them still sends one" do
      # Headless first, deliberately: with the browser first, deleting the
      # headless wiring entirely would still leave this green.
      {user, _secret} = enabled_user()
      cleanup(user)

      pending = headless_pending(user)
      Enum.each(1..(@budget + 1), fn _ -> headless_verify(pending, "000000") end)
      drain_oban()
      assert_email_sent(fn mail -> assert mail.subject =~ @subject end)

      browser_verify(user, "000000")
      drain_oban()

      assert_no_email_sent()
    end
  end

  describe "what the mail may not claim" do
    test "a first factor that was not a password still gets an accurate mail" do
      # `AuthController.success/4` is the callback for EVERY strategy, so a
      # magic link or an OIDC assertion diverts to the code prompt exactly as a
      # password does. For those users the compromised thing is their mailbox or
      # their IdP, and a mail saying "someone has your password" would send them
      # to secure the wrong account. The pending token carries no strategy, so
      # the copy has to hold for all of them.
      {user, _secret} = enabled_user()
      cleanup(user)

      exhaust(user)
      browser_verify(user, "000000")
      drain_oban()

      assert_email_sent(fn mail ->
        refute mail.html_body =~ "signed in to your"
        assert mail.html_body =~ "receives your sign-in links"
        assert mail.html_body =~ "single sign-on"
      end)
    end

    test "a budget spent at /editor/settings still produces an accurate mail" do
      # #727 gave the settings forms the same bucket, so an owner who fumbles
      # codes while regenerating their recovery set and *then* signs in trips
      # this alert with no attacker anywhere — the likeliest trigger in
      # practice. The mail must not accuse, and the benign explanation must come
      # before the alarming one.
      {user, secret} = enabled_user()
      cleanup(user)

      Enum.each(1..@budget, fn _ ->
        KilnCMS.Accounts.disable_totp(user, %{code: "000000"}, actor: user)
      end)

      code = TwoFactorFixtures.current_code(secret)
      assert browser_verify(user, code).status == 429
      drain_oban()

      assert_email_sent(fn mail ->
        body = mail.html_body
        assert body =~ "If that was you"
        # ...and it says so before it raises the possibility of an intruder.
        assert :binary.match(body, "If that was you") < :binary.match(body, "If it wasn't you")
      end)
    end
  end

  describe "failure handling" do
    test "a delivery failure hands the alert window back" do
      # The window is claimed before the mail is built, because `hit/3` is one
      # atomic increment-and-compare and splitting it would let two concurrent
      # refusals both send. The cost is that a wedged queue would otherwise eat
      # six hours of alerts along with the one mail.
      {user, _secret} = enabled_user()
      cleanup(user)

      previous = Application.fetch_env!(:kiln_cms, :email_from)
      Application.delete_env(:kiln_cms, :email_from)
      on_exit(fn -> Application.put_env(:kiln_cms, :email_from, previous) end)

      exhaust(user)
      # Must not break the sign-in it is reporting on.
      assert browser_verify(user, "000000").status == 429
      drain_oban()
      assert_no_email_sent()

      Application.put_env(:kiln_cms, :email_from, previous)
      browser_verify(user, "000000")
      drain_oban()

      assert_email_sent(fn mail -> assert mail.subject =~ @subject end)
    end

    test "a caller that is not a loaded user cannot raise" do
      # The head clause runs *before* the implicit `try`, so a `%User{}`-only
      # head would 500 the sign-in rather than swallow.
      assert :ok = KilnCMS.Accounts.SignInAlert.second_factor_locked(nil)
      assert :ok = KilnCMS.Accounts.SignInAlert.second_factor_locked(%{id: "not-a-user"})
    end
  end

  describe "which alarm rings first" do
    test "the second-factor budget is reached first, from one pending token" do
      # #728's original claim was that the password alert could *never* fire on
      # this attack, because re-running the first factor forgave its counter.
      # #742 closed that reset, so it can now fire — eventually. This alert is
      # still the one that carries the news, because the whole second-factor
      # budget is spendable against a SINGLE pending token, i.e. one first
      # factor, so it is reached long before the sign-in budget has been
      # touched more than once.
      #
      # (`KilnCMS.Accounts.SignInCounterTest` owns the held-counter behaviour
      # itself; this only pins the ordering.)
      {user, _secret} = enabled_user()
      cleanup(user)
      address = to_string(user.email)

      # One real first factor, then the whole code budget against its token.
      pending = headless_pending(user)
      Enum.each(1..(@budget + 1), fn _ -> headless_verify(pending, "000000") end)
      drain_oban()

      assert_email_sent(fn mail ->
        refute mail.subject =~ @password_alert_subject
        assert mail.subject =~ @subject
      end)

      # And the sign-in budget has barely been touched: one unit, held rather
      # than forgiven (#742), with the shipped budget of ten still to go.
      assert :allow = AccountThrottle.consume(address)
    end

    test "the second-factor alert has its own window, so the password alert can't suppress it" do
      {user, _secret} = enabled_user()
      cleanup(user)

      # Burn the sign-in alert's window under BOTH keyings. The address is what
      # `account_locked/1` actually passes; the user id is what would collide if
      # `second_factor_alert_allowed?/1` were ever changed to share the
      # `"signin:alert"` prefix — which is the bug this test names, and which
      # burning the address alone cannot detect.
      assert AccountThrottle.alert_allowed?(to_string(user.email))
      assert AccountThrottle.alert_allowed?(user.id)

      exhaust(user)
      browser_verify(user, "000000")
      drain_oban()

      assert_email_sent(fn mail ->
        refute mail.subject =~ @password_alert_subject
        assert mail.subject =~ @subject
      end)
    end
  end

  # Reaching the settings forms needs a live SESSION, not a password. So a
  # lockout there says something the sign-in alerts do not, and #757 is about
  # saying it — previously `ThrottleSecondFactor`'s deny branch mailed nobody,
  # which is the one lockout with no other symptom for the owner to notice.
  describe "settings forms (#757)" do
    @settings_subject "Two-factor settings changes blocked"

    # `@budget + 1`: the budget is what is ALLOWED, so the refusal — and the
    # alert with it — lands on the attempt after. The sign-in `exhaust/1` above
    # needs only `@budget` because that path spends a unit minting the pending
    # token before the code is ever checked.
    defp exhaust_settings(user) do
      Enum.each(1..(@budget + 1), fn _ ->
        KilnCMS.Accounts.disable_totp(user, %{code: "000000"}, actor: user)
      end)

      drain_oban()
    end

    test "a lockout at the settings forms alerts the owner" do
      {user, _secret} = enabled_user()

      exhaust_settings(user)

      assert_email_sent(fn email -> email.subject =~ @settings_subject end)
    end

    test "the copy names a stolen SESSION, not a stolen password" do
      {user, _secret} = enabled_user()

      exhaust_settings(user)

      assert_email_sent(fn email ->
        body = email.html_body

        assert body =~ "already signed in"
        assert body =~ "live session"
        # The sign-in mail's framing would be wrong here: no password was used.
        refute body =~ "completed the first step of signing in"
        # And the first action is ending their session, not securing a password
        # in the abstract — the reset link is offered *because* it signs
        # everyone out.
        assert body =~ "signs out every other"
        true
      end)
    end

    test "it does not send the sign-in second-factor mail" do
      {user, _secret} = enabled_user()

      exhaust_settings(user)

      # The settings mail went; the sign-in one must not have. Asserting on the
      # subject of what arrived is the check — `refute_email_sent/1` takes a
      # pattern, not a predicate.
      assert_email_sent(fn email ->
        assert email.subject =~ @settings_subject
        refute email.subject =~ @subject
        true
      end)

      assert_no_email_sent()
    end

    test "one mail per window, not one per refusal" do
      {user, _secret} = enabled_user()

      exhaust_settings(user)
      # Keep failing past the budget.
      exhaust_settings(user)

      assert_email_sent(fn email -> email.subject =~ @settings_subject end)
      # Nothing else in the mailbox: the second run was suppressed.
      assert_no_email_sent()
    end

    # The budgets are strictly ordered — a settings lockout is the strongest of
    # the three — so a sign-in lockout must not have spent this one.
    # The three budgets are strictly ordered — a settings lockout is the
    # strongest — so spending the sign-in one must leave this one intact.
    # Asserted directly on the budget rather than through the mailer, which is
    # what the sign-in path leaves conn responses in.
    test "its window is its own, not shared with the sign-in alert" do
      {user, _secret} = enabled_user()

      # Spend the SIGN-IN second-factor alert window.
      assert AccountThrottle.second_factor_alert_allowed?(user.id)
      refute AccountThrottle.second_factor_alert_allowed?(user.id)

      # The settings window is untouched by that.
      assert AccountThrottle.settings_second_factor_alert_allowed?(user.id)
      refute AccountThrottle.settings_second_factor_alert_allowed?(user.id)
    end

    # It runs inside an `Ash.Changeset` build, so it must not be able to break
    # either the action or the build.
    test "the refusal still lands if the alert cannot be sent" do
      {user, _secret} = enabled_user()

      # Capture and RESTORE. `delete_env` in `on_exit` removes a key
      # `config/test.exs` sets, leaking the default into every later test in
      # the file — which is exactly how this broke the eleven tests above it.
      previous = Application.fetch_env(:kiln_cms, :email_from)
      Application.put_env(:kiln_cms, :email_from, nil)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kiln_cms, :email_from, value)
          :error -> Application.delete_env(:kiln_cms, :email_from)
        end
      end)

      assert {:error, _} = KilnCMS.Accounts.disable_totp(user, %{code: "000000"}, actor: user)
    end
  end
end
