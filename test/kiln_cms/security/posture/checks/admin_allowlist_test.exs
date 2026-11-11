defmodule KilnCMS.Security.Posture.Checks.AdminAllowlistTest do
  @moduledoc """
  `core.admin_allowlist` (#2252) against the site's real list, with and
  without the operator's switch, and with a list that cannot be read.

  `async: false`: the switch (`KILN_ADMIN_ALLOWLIST_DISABLED`) is application
  env, which is node-wide.
  """
  use KilnCMS.DataCase, async: false

  # The unreadable-row cases log the refused read on purpose.
  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Security.Posture.Checks.AdminAllowlist

  @me {203, 0, 113, 7}

  setup do
    original = Application.get_env(:kiln_cms, :admin_allowlist, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :admin_allowlist, original) end)

    site = org("pfaal")
    %{site: site, admin: user(:viewer) |> member!(site, :admin)}
  end

  defp list!(site, admin, cidrs) do
    {:ok, _row} =
      CMS.save_site_admin_allowlist(%{cidrs: cidrs},
        actor: admin,
        tenant: site.id,
        context: %{client_ip: @me}
      )
  end

  defp switch!(on?) do
    Application.put_env(
      :kiln_cms,
      :admin_allowlist,
      Keyword.put(Application.get_env(:kiln_cms, :admin_allowlist, []), :disabled, on?)
    )
  end

  test "no list is not applicable, switch or not", %{site: site} do
    assert %{status: :n_a, facts: %{entries: 0}} = AdminAllowlist.run(context(site))

    switch!(true)
    assert %{status: :n_a} = AdminAllowlist.run(context(site))
  end

  test "a list passes, and fails while the operator's switch ignores it", %{
    site: site,
    admin: admin
  } do
    list!(site, admin, ["203.0.113.0/24", "198.51.100.0/24"])

    assert %{status: :pass, facts: %{entries: 2, operator_disabled: false}} =
             AdminAllowlist.run(context(site))

    switch!(true)

    assert %{status: :fail, facts: %{operator_disabled: true}} =
             AdminAllowlist.run(context(site))
  end

  test "a list that cannot be read is unknown", %{site: site} do
    # A site this node has never read: nothing cached, no last-known value.
    result = KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.run(context(site)) end)
    assert result.status == :unknown
  end
end
