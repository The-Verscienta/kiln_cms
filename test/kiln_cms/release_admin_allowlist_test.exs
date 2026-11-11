defmodule KilnCMS.ReleaseAdminAllowlistTest do
  @moduledoc """
  `KilnCMS.Release.admin_allowlist/1` (#2248): the operator's way back in when
  a site's admin allowlist has locked its admins out. Lists, widens an active
  list or empties it — never narrows, never turns one on — as the `:operator`
  system actor, records the change in the site's security log and reaches the
  gates at once.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureIO
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Release
  alias KilnCMS.Security
  alias KilnCMS.Security.AdminAllowlist

  @me {203, 0, 113, 7}

  setup do
    %{site: org("aal-rel")}
  end

  defp save!(site, cidrs) do
    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "aal-rel-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: admin.id,
      role: :admin
    })

    CMS.save_site_admin_allowlist!(%{cidrs: cidrs},
      actor: admin,
      tenant: site.id,
      context: %{client_ip: @me}
    )
  end

  defp run(site, opts, serving? \\ true) do
    test = self()
    opts = Keyword.put(opts, :org, site.slug)

    out =
      capture_io(fn -> send(test, {:result, Release.run_admin_allowlist(opts, serving?)}) end)

    assert_received {:result, result}
    {result, out}
  end

  test "lists an active list and changes nothing", %{site: site} do
    save!(site, ["203.0.113.0/24"])

    assert {{:ok, ["203.0.113.0/24"]}, out} = run(site, [])
    assert out =~ "is on, with 1 entr"
    assert out =~ "203.0.113.0/24"
    assert out =~ "Nothing changed"
  end

  test "says when the list is off", %{site: site} do
    assert {{:ok, []}, out} = run(site, [])
    assert out =~ "is off"
  end

  test "clear empties the list, reaches the gate at once and is in the log", %{site: site} do
    save!(site, ["203.0.113.0/24"])
    assert AdminAllowlist.check(site.id, {198, 51, 100, 9}) == :not_listed

    assert {{:ok, []}, out} = run(site, clear: true)
    assert out =~ "Cleared the admin allowlist"
    assert AdminAllowlist.check(site.id, {198, 51, 100, 9}) == :allowed

    assert [%{metadata: %{"change" => "cleared"}}] = events(site)
  end

  test "add widens an active list and is in the log", %{site: site} do
    save!(site, ["203.0.113.0/24"])

    assert {{:ok, ["203.0.113.0/24", "198.51.100.9/32"]}, out} = run(site, add: "198.51.100.9")
    assert out =~ "Added 198.51.100.9/32"
    assert AdminAllowlist.check(site.id, {198, 51, 100, 9}) == :allowed
    assert [%{metadata: %{"change" => "added"}}] = events(site)
  end

  test "add of an entry already listed changes nothing and records nothing", %{site: site} do
    save!(site, ["203.0.113.0/24"])

    assert {{:error, message}, _out} = run(site, add: "203.0.113.0/24")
    assert message =~ "already on the admin allowlist"
    assert events(site) == []
  end

  test "add to a list that is off is refused: it would turn the list on", %{site: site} do
    assert {{:error, message}, out} = run(site, add: "198.51.100.9")
    assert message =~ "is off on this site"
    assert out =~ message
    assert AdminAllowlist.policy(site.id) == :off
    assert events(site) == []
  end

  test "clear on a list that is off changes nothing", %{site: site} do
    assert {{:ok, []}, out} = run(site, clear: true)
    assert out =~ "already off"
    assert events(site) == []
  end

  test "an entry that is not an address, both options, and an unknown site are errors", %{
    site: site
  } do
    save!(site, ["203.0.113.0/24"])

    assert {{:error, message}, _out} = run(site, add: "office")
    assert message =~ "not an IP address or range"

    assert {{:error, message}, _out} = run(site, add: "198.51.100.9", clear: true)
    assert message =~ "not both"

    assert {{:error, message}, _out} = run(%{site | slug: "no-such-site"}, clear: true)
    assert message =~ "No organization"

    assert CMS.list_site_admin_allowlist!(
             actor: KilnCMS.SystemActor.new(:operator),
             tenant: site.id
           )
           |> hd()
           |> Map.get(:cidrs) == ["203.0.113.0/24"]
  end

  test "refuses to run without the serving application (eval, not rpc)", %{site: site} do
    save!(site, ["203.0.113.0/24"])
    assert {{:error, message}, _out} = run(site, [clear: true], false)
    assert message =~ "bin/kiln_cms rpc"
    assert {:on, _} = AdminAllowlist.policy(site.id)
  end

  defp events(site) do
    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "aal-rel-reader-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    Security.list_events!(actor: admin, tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :admin_allowlist_overridden))
  end
end
