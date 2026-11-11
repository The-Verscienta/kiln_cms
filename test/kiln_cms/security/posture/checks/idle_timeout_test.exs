defmodule KilnCMS.Security.Posture.Checks.IdleTimeoutTest do
  @moduledoc """
  `core.idle_timeout` (#2252) against the site's real `SiteSessionPolicy` row,
  including the row that cannot be read, which must be unknown rather than
  "never signed out".
  """
  use KilnCMS.DataCase, async: true

  # The unreadable-row cases log the refused read on purpose.
  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Security.Posture.Checks.IdleTimeout

  setup do
    %{site: org("pfidle")}
  end

  defp policy!(site, attrs) do
    CMS.save_site_session_policy!(attrs, actor: user(:admin), tenant: site.id)
  end

  test "passes with a timeout, and warns once it is cleared", %{site: site} do
    policy!(site, %{idle_timeout_minutes: 30})

    assert %{status: :pass, facts: %{idle_minutes: 30, admin_idle_minutes: nil}} =
             IdleTimeout.run(context(site))

    policy!(site, %{idle_timeout_minutes: nil})

    assert %{status: :warn, fix_path: "/editor/sessions"} = IdleTimeout.run(context(site))
  end

  test "an administrators-only timeout passes", %{site: site} do
    policy!(site, %{admin_idle_timeout_minutes: 15})
    assert %{status: :pass, facts: %{admin_idle_minutes: 15}} = IdleTimeout.run(context(site))
  end

  test "no row warns", %{site: site} do
    assert %{status: :warn} = IdleTimeout.run(context(site))
  end

  test "a row that cannot be read is unknown, not off", %{site: site} do
    policy!(site, %{idle_timeout_minutes: 30})

    result = KilnCMS.OrgSettings.with_actor(nil, fn -> IdleTimeout.run(context(site)) end)

    assert result.status == :unknown
  end
end
