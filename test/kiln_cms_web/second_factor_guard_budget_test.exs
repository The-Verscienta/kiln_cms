defmodule KilnCMSWeb.SecondFactorGuardBudgetTest do
  @moduledoc """
  What the #2247 guards cost the shared second-factor budget: refusing to
  turn off an account's last factor costs nothing (the refusal is decided
  before the budget is charged, and no code is compared), and the policy
  page's preview builds no changeset, so typing a code into its form charges
  nothing until it is submitted.

  `async: false` because the test config lifts every throttle budget out of
  reach and this module puts a real one back with `Application.put_env`, a
  process-wide write (as `KilnCMS.CMS.SiteSecondFactorPolicyBudgetTest`).
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  @budget 3

  setup do
    previous = Application.get_env(:kiln_cms, AccountThrottle, [])

    Application.put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.merge(previous,
        second_factor_budget: @budget,
        second_factor_window: :timer.hours(1)
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, AccountThrottle, previous) end)
  end

  defp app_member(site, role) do
    {user, secret} = TwoFactorFixtures.enabled_user(role: :viewer, inserted_at: long_ago())
    {member!(user, site, role), secret}
  end

  test "refusing to turn off the last factor spends no attempt" do
    site = org("sfgb-last")
    policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
    {user, secret} = app_member(site, :editor)

    for _attempt <- 1..(@budget + 1) do
      code = Totp.code_at(secret, System.system_time(:second))
      assert {:error, _} = Accounts.disable_totp(user, %{code: code}, actor: user)
    end

    assert AccountThrottle.consume_second_factor(user.id) == :allow
  end

  test "a wrong code where nothing is required still spends one" do
    site = org("sfgb-control")
    {user, _secret} = app_member(site, :editor)

    for _attempt <- 1..@budget do
      assert {:error, _} = Accounts.disable_totp(user, %{code: "000000"}, actor: user)
    end

    assert {:deny, _retry_after} = AccountThrottle.consume_second_factor(user.id)
  end

  test "the policy page's preview charges no code, however often the form changes", %{
    conn: conn
  } do
    site = org("sfgb-preview")
    {admin, _secret} = app_member(site, :admin)

    {:ok, view, _html} = conn |> signed_in(admin, site) |> live(~p"/editor/two-factor")

    for _change <- 1..(@budget + 1) do
      view
      |> form("#two-factor-policy-form",
        policy: %{required_for: "everyone", grace_days: "0", code: "000000"}
      )
      |> render_change()
    end

    assert AccountThrottle.consume_second_factor(admin.id) == :allow
  end
end
