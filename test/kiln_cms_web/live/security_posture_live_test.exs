defmodule KilnCMSWeb.SecurityPostureLiveTest do
  @moduledoc """
  The console screen behind `/editor/security-posture` (#2252): admin-only,
  about the request's site; the installation's checks for platform admins
  only; fix links; a check that crashes is a row, not a broken page; and
  "Run checks again" re-checks the tier.

  `async: false`: the crashing check is installed through application env, and
  the platform admin's release check reads `Kiln.Updates`' node-wide cache.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @moduletag :capture_log
  @password "password1234!"

  defmodule Crashing do
    use Kiln.Security.Check
    def id, do: "test.crashing"
    def title, do: "A check that crashes"
    def scope, do: :site
    def run(_context), do: raise("plugin internals")
  end

  defmodule Slow do
    use Kiln.Security.Check
    def id, do: "test.slow"
    def title, do: "A slow check"
    def scope, do: :site

    def run(_context) do
      Process.sleep(400)
      pass("Done.")
    end
  end

  setup do
    Kiln.Updates.put_cache({:ok, :current})
    original = Application.get_env(:kiln_cms, KilnCMS.Security.Posture, [])

    on_exit(fn ->
      Kiln.Updates.clear_cache()
      Application.put_env(:kiln_cms, KilnCMS.Security.Posture, original)
    end)

    %{site: org("pfweb")}
  end

  defp open(conn, site, user) do
    {:ok, lv, _html} =
      conn |> org_conn(site) |> log_in(user) |> live(~p"/editor/security-posture")

    {lv, render_async(lv, 2_000)}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/security-posture")
    end

    for role <- [:editor, :viewer] do
      test "turns away a #{role} of this very site", %{conn: conn, site: site} do
        user = authed_user(:viewer)
        member!(user, site, unquote(role))

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(site) |> log_in(user) |> live(~p"/editor/security-posture")
      end
    end

    test "turns away an admin of another site", %{conn: conn, site: site} do
      outsider = authed_user(:viewer)
      member!(outsider, org("pfweb-other"), :admin)

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> org_conn(site) |> log_in(outsider) |> live(~p"/editor/security-posture")
    end
  end

  test "a site admin sees the site's checks, with fix links, and no installation section", %{
    conn: conn,
    site: site
  } do
    admin = authed_user(:viewer)
    member!(admin, site, :admin)

    {lv, html} = open(conn, site, admin)

    assert html =~ "Security posture"
    assert has_element?(lv, "#security-posture-summary")
    assert has_element?(lv, "#security-posture-site")
    refute has_element?(lv, "#security-posture-deployment")
    refute has_element?(lv, "#posture-core-transport")

    # The admin has no authenticator app: the site's own check fails, names
    # them, and links to where they fix it.
    assert has_element?(lv, "#posture-core-second_factor", "Fix now")
    assert has_element?(lv, "#posture-core-second_factor li", to_string(admin.email))
    assert has_element?(lv, ~s(#posture-core-second_factor a[href="/editor/settings"]), "Fix")
    assert has_element?(lv, ~s(#posture-core-idle_timeout a[href="/editor/sessions"]))

    assert has_element?(
             lv,
             ~s(#posture-core-idle_timeout a[target="_blank"][href^="https://"]),
             "Learn more"
           )

    # The dependency plugin's check is a row, credited to its plugin.
    assert has_element?(lv, "#posture-dep_fixture-build_env", "kiln_dep_fixture")
  end

  test "a site that turned its idle timeout on shows it as OK", %{conn: conn, site: site} do
    admin = authed_user(:viewer)
    member!(admin, site, :admin)
    CMS.save_site_session_policy!(%{idle_timeout_minutes: 30}, actor: admin, tenant: site.id)

    {lv, _html} = open(conn, site, admin)
    assert has_element?(lv, "#posture-core-idle_timeout", "OK")
  end

  test "a platform admin also sees the installation's checks", %{conn: conn, site: site} do
    {lv, html} = open(conn, site, authed_user(:admin))

    assert has_element?(lv, "#security-posture-deployment")
    assert has_element?(lv, "#posture-core-transport", "Not applicable")
    assert has_element?(lv, "#posture-core-operator_second_factor")
    assert html =~ "This is the newest Kiln release."
    # The notices feed is off in this suite (`config/test.exs`).
    assert has_element?(lv, "#posture-core-security_notices", "Security notices for Kiln")
    assert has_element?(lv, "#posture-core-security_notices", "Not applicable")
  end

  test "a check that crashes is a row that says so, and the page still draws", %{
    conn: conn,
    site: site
  } do
    Application.put_env(:kiln_cms, KilnCMS.Security.Posture, checks: [__MODULE__.Crashing])
    admin = authed_user(:viewer)
    member!(admin, site, :admin)

    {lv, html} = open(conn, site, admin)

    assert has_element?(lv, "#posture-test-crashing", "Could not run")
    assert has_element?(lv, "#posture-test-crashing", "This check could not run: it failed.")
    refute html =~ "plugin internals"
    assert has_element?(lv, "#posture-core-second_factor")
    assert has_element?(lv, "#security-posture-counts", "1 could not run")
  end

  test "Run checks again runs them again", %{conn: conn, site: site} do
    admin = authed_user(:viewer)
    member!(admin, site, :admin)
    {lv, _html} = open(conn, site, admin)
    assert has_element?(lv, "#posture-core-idle_timeout", "Review")

    CMS.save_site_session_policy!(%{idle_timeout_minutes: 30}, actor: admin, tenant: site.id)
    lv |> element("#security-posture-rerun") |> render_click()
    render_async(lv, 2_000)

    assert has_element?(lv, "#posture-core-idle_timeout", "OK")
  end

  test "Run checks again is refused while a run is in flight", %{conn: conn, site: site} do
    Application.put_env(:kiln_cms, KilnCMS.Security.Posture, checks: [__MODULE__.Slow])
    admin = authed_user(:viewer)
    member!(admin, site, :admin)

    {:ok, lv, _html} =
      conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/security-posture")

    # The mount-time run is still waiting on the slow check.
    html = lv |> element("#security-posture-rerun") |> render_click()
    assert html =~ "The checks are already running."

    render_async(lv, 2000)
    assert has_element?(lv, "#posture-test-slow", "OK")
  end

  test "Run checks again is refused a second time within a few seconds", %{
    conn: conn,
    site: site
  } do
    admin = authed_user(:viewer)
    member!(admin, site, :admin)
    {lv, _html} = open(conn, site, admin)

    refute lv |> element("#security-posture-rerun") |> render_click() =~ "just ran"
    render_async(lv, 2_000)

    assert lv |> element("#security-posture-rerun") |> render_click() =~
             "The checks just ran. Try again in a few seconds."
  end

  test "a site with its reports all running says busy, not forbidden", %{
    conn: conn,
    site: site
  } do
    holders = hold_slots(site.id)
    on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)

    admin = authed_user(:viewer)
    member!(admin, site, :admin)
    {lv, html} = open(conn, site, admin)

    assert html =~ "already running for this site"
    refute html =~ "permission"
    assert has_element?(lv, "#security-posture-failed")
  end

  test "an admin demoted while the page is open is refused on Run checks again", %{
    conn: conn,
    site: site
  } do
    admin = authed_user(:viewer)
    membership = member!(admin, site, :admin)
    {lv, _html} = open(conn, site, admin)

    Ash.Seed.update!(membership, %{role: :viewer})

    html = lv |> element("#security-posture-rerun") |> render_click()
    assert html =~ "permission to see this site"
  end

  test "is in the console nav for an admin, under Organization", %{conn: conn, site: site} do
    admin = authed_user(:viewer)
    member!(admin, site, :admin)

    nav = KilnCMSWeb.ConsoleNav.nav(admin, site)
    group = Enum.find(nav.configure_groups, &(&1.key == :organization))
    assert Enum.any?(group.items, &(&1.key == :security_posture))

    editor = authed_user(:viewer)
    member!(editor, site, :editor)

    refute KilnCMSWeb.ConsoleNav.nav(editor, site).configure_groups
           |> Enum.flat_map(& &1.items)
           |> Enum.any?(&(&1.key == :security_posture))

    _ = conn
  end

  # Occupy every report slot of `org_id`, as that many running reports would.
  defp hold_slots(org_id) do
    test = self()

    for _ <- 1..KilnCMS.Security.Posture.max_per_org() do
      pid =
        spawn(fn ->
          Registry.register(KilnCMS.Security.Posture.slots(), org_id, nil)
          send(test, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held
      pid
    end
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: role
    })
  end

  defp authed_user(role) do
    email = "pfweb-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
