defmodule KilnCMS.CMS.SiteSecondFactorPolicyBudgetTest do
  @moduledoc """
  A code given to save a site's two-step sign-in requirement (#2247) is charged
  to the account's shared second-factor budget, and a refused save's rollback
  does not refund it.

  `async: false` because the test config lifts every throttle budget out of
  reach and this module puts the real one back with `Application.put_env`, a
  process-wide write (as `KilnCMS.Accounts.SecondFactorSettingsBudgetTest`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.SecondFactorThrottled
  alias KilnCMS.CMS
  alias KilnCMS.TwoFactorFixtures

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

    site = org("sfp-budget")

    {admin, secret} =
      TwoFactorFixtures.enabled_user(
        role: :viewer,
        email: "sfp-budget-#{System.unique_integer([:positive])}@example.com"
      )

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: admin.id,
      role: :admin
    })

    %{site: site, admin: admin, secret: secret}
  end

  defp save(code, admin, site) do
    CMS.save_site_second_factor_policy(%{required_for: :admins, code: code},
      actor: admin,
      tenant: site.id
    )
  end

  defp throttled?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%SecondFactorThrottled{}, &1))

  defp throttled?(_other), do: false

  test "wrong codes spend the budget even though each save rolls back", %{
    site: site,
    admin: admin,
    secret: secret
  } do
    for _attempt <- 1..@budget do
      result = save("000000", admin, site)
      refute throttled?(result)
      assert {:error, _} = result
    end

    # Had the charge been made inside the refused write's transaction, its
    # rollback would have refunded it and this correct code would pass.
    assert throttled?(save(TwoFactorFixtures.current_code(secret), admin, site))
  end

  test "a correct code clears the failures before it", %{
    site: site,
    admin: admin,
    secret: secret
  } do
    for _attempt <- 1..(@budget - 1), do: save("000000", admin, site)

    assert {:ok, _} = save(TwoFactorFixtures.current_code(secret), admin, site)

    for _attempt <- 1..(@budget - 1), do: refute(throttled?(save("000000", admin, site)))
  end
end
