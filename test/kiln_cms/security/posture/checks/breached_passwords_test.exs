defmodule KilnCMS.Security.Posture.Checks.BreachedPasswordsTest do
  @moduledoc """
  `core.breached_passwords` (#2252) against the site's real
  `SitePasswordPolicy` row and the deployment switch.

  `async: false`: the switch (`BREACHED_PASSWORD_CHECK`) is application env.
  """
  use KilnCMS.DataCase, async: false

  # The unreadable-row cases log the refused read on purpose.
  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.CMS
  alias KilnCMS.Security.Posture.Checks.BreachedPasswords

  setup do
    original = Application.get_env(:kiln_cms, BreachedPassword, [])
    Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, BreachedPassword, original) end)

    site = org("pfpw")
    save!(site, :block)
    %{site: site, original: original}
  end

  defp save!(site, policy) do
    CMS.save_site_password_policy!(%{breached_password_policy: policy},
      actor: user(:admin),
      tenant: site
    )
  end

  test ":block passes", %{site: site} do
    assert %{status: :pass, facts: %{admin_policy: "block"}} =
             BreachedPasswords.run(context(site))
  end

  test ":warn warns", %{site: site} do
    save!(site, :warn)
    assert %{status: :warn, facts: %{admin_policy: "warn"}} = BreachedPasswords.run(context(site))
  end

  test ":off fails", %{site: site} do
    save!(site, :off)
    assert %{status: :fail, facts: %{admin_policy: "off"}} = BreachedPasswords.run(context(site))
  end

  test "the deployment switch off fails, whatever the site says", %{
    site: site,
    original: original
  } do
    Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, false))

    result = BreachedPasswords.run(context(site))
    assert result.status == :fail
    assert result.facts.deployment_enabled == false
    assert result.summary =~ "BREACHED_PASSWORD_CHECK"
  end

  test "a row that cannot be read is unknown, not :warn", %{site: site} do
    result = KilnCMS.OrgSettings.with_actor(nil, fn -> BreachedPasswords.run(context(site)) end)
    assert result.status == :unknown
  end
end
