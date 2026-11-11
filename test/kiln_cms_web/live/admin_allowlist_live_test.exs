defmodule KilnCMSWeb.AdminAllowlistLiveTest do
  @moduledoc """
  `/editor/admin-allowlist` (#2248): who may open and change it, the address it
  shows and checks a save against (the one the HTTP gate admitted, and the
  socket's when it differs), "Add my address", turning the list off, and the
  warnings for an untrusted proxy, a shared address and the operator's switch.

  `async: false`: some tests set `Application.put_env` (proxy settings, the
  operator's switch), which is node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @moduletag :capture_log

  @password "password1234!"
  @me {203, 0, 113, 7}

  setup do
    %{site: org("aallive")}
  end

  defp user_of(site, role), do: site |> member_of(role) |> elem(0)

  defp member_of(site, role) do
    email = "aallive-#{role}-#{System.unique_integer([:positive])}@example.com"

    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: email,
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    membership =
      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: site.id,
        user_id: user.id,
        role: role
      })

    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(Accounts.User, :password),
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    {user, membership}
  end

  defp from(conn, site, address) do
    %Plug.Conn{} =
      conn = Plug.Test.put_peer_data(conn, %{address: address, port: 1, ssl_cert: nil})

    org_conn(%Plug.Conn{conn | remote_ip: address}, site)
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open(conn, site, address \\ @me, role \\ :admin) do
    conn
    |> from(site, address)
    |> log_in(user_of(site, role))
    |> live(~p"/editor/admin-allowlist")
  end

  defp stored(site) do
    case CMS.list_site_admin_allowlist(
           actor: KilnCMS.SystemActor.new(:operator),
           tenant: site.id,
           authorize_with: :error
         ) do
      {:ok, [row]} -> row.cidrs
      {:ok, []} -> nil
    end
  end

  defp submit(lv, text),
    do: lv |> form("#admin-allowlist-form", allowlist: %{"cidrs" => text}) |> render_submit()

  defp restore_env(key) do
    previous = Application.get_env(:kiln_cms, key)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, key),
        else: Application.put_env(:kiln_cms, key, previous)
    end)
  end

  describe "who may use it" do
    test "an editor and a viewer are turned away", %{conn: conn, site: site} do
      for role <- [:editor, :viewer] do
        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 open(conn, site, @me, role)

        refute CMS.can_save_site_admin_allowlist?(user_of(site, role), %{cidrs: []},
                 tenant: site.id
               )
      end
    end

    test "a visitor who is not signed in is sent to sign in", %{conn: conn, site: site} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               conn |> from(site, @me) |> live(~p"/editor/admin-allowlist")
    end

    test "an admin of another site is turned away on this site's host", %{
      conn: conn,
      site: site
    } do
      other_admin = user_of(org("aallive-other"), :admin)

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn
               |> from(site, @me)
               |> log_in(other_admin)
               |> live(~p"/editor/admin-allowlist")
    end
  end

  describe "saving" do
    test "the admin sees the list is off and their address", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)

      assert has_element?(
               lv,
               "#admin-allowlist-status",
               "Off: people can sign in from any network."
             )

      assert has_element?(lv, ".admin-allowlist-address", "Your address: 203.0.113.7 (included)")
      assert has_element?(lv, "#admin-allowlist-members", "mobile app")
    end

    test "a list including the admin's address saves, normalised, for this site only", %{
      conn: conn,
      site: site
    } do
      other = org("aallive-elsewhere")
      {:ok, lv, _html} = open(conn, site)

      html = submit(lv, "203.0.113.0/24\n198.51.100.9")

      assert html =~ "Admin allowlist saved."
      assert stored(site) == ["203.0.113.0/24", "198.51.100.9/32"]
      assert stored(other) == nil
      assert has_element?(lv, "#admin-allowlist-status", "On: 2 networks")
    end

    test "a list without the admin's address is refused, naming it, and nothing changes", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = open(conn, site)

      html = submit(lv, "198.51.100.0/24")

      assert html =~ "doesn&#39;t include your current address, 203.0.113.7"
      assert stored(site) == nil
    end

    test "an entry that is not allowed is named in the error", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)

      html = submit(lv, "203.0.113.0/24\n0.0.0.0/4\n::1\noffice")

      assert html =~ "0.0.0.0/4 is too broad"
      assert html =~ "::1 includes loopback"
      assert html =~ "office is not an IP address or range"
      assert stored(site) == nil
    end

    test "Add my address adds it to the form; saving keeps it", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)

      lv |> element("#admin-allowlist-add-mine") |> render_click()
      assert has_element?(lv, "#admin-allowlist-form textarea", "203.0.113.7/32")

      html = lv |> element("#admin-allowlist-form") |> render_submit()
      assert html =~ "Admin allowlist saved."
      assert stored(site) == ["203.0.113.7/32"]
    end

    test "Add my address adds an IPv6 client's /64", %{conn: conn, site: site} do
      v6 = {0x2001, 0xDB8, 4, 5, 6, 7, 8, 9}
      {:ok, lv, _html} = open(conn, site, v6)

      assert has_element?(lv, "#admin-allowlist-you", "connected over IPv6")
      lv |> element("#admin-allowlist-add-mine") |> render_click()
      assert has_element?(lv, "#admin-allowlist-form textarea", "2001:db8:4:5::/64")
    end

    test "Turn off saves an empty list", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)
      submit(lv, "203.0.113.0/24")

      html = lv |> element("#admin-allowlist-turn-off") |> render_click()

      assert html =~ "Admin allowlist turned off."
      assert stored(site) == []
    end

    test "an admin demoted while the page is open is refused on the next event", %{
      conn: conn,
      site: site
    } do
      {admin, membership} = member_of(site, :admin)

      {:ok, lv, _html} =
        conn |> from(site, @me) |> log_in(admin) |> live(~p"/editor/admin-allowlist")

      Ash.Seed.update!(membership, %{role: :viewer})

      html = submit(lv, "203.0.113.0/24")
      assert html =~ "permission"
      assert stored(site) == nil
    end
  end

  describe "Also restrict sign-in (#2493)" do
    defp stored_row(site) do
      {:ok, [row]} =
        CMS.list_site_admin_allowlist(
          actor: KilnCMS.SystemActor.new(:operator),
          tenant: site.id,
          authorize_with: :error
        )

      row
    end

    defp submit(lv, text, restrict),
      do:
        lv
        |> form("#admin-allowlist-form",
          allowlist: %{"cidrs" => text, "restrict_sign_in" => to_string(restrict)}
        )
        |> render_submit()

    test "is checked by default, and the page says sign-in is restricted", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = open(conn, site)

      assert has_element?(lv, "#admin-allowlist-restrict-sign-in[checked]")
      submit(lv, "203.0.113.0/24")

      assert stored_row(site).restrict_sign_in == true
      assert has_element?(lv, "#admin-allowlist-status", "can open the console and sign in")
      assert has_element?(lv, "#admin-allowlist-members")
    end

    test "unchecked, it saves with the list and the page says anyone can sign in", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = open(conn, site)

      assert submit(lv, "203.0.113.0/24", false) =~ "Admin allowlist saved."

      row = stored_row(site)
      assert row.cidrs == ["203.0.113.0/24"]
      refute row.restrict_sign_in
      assert has_element?(lv, "#admin-allowlist-status", "Anyone can sign in from any network")
      assert has_element?(lv, "#admin-allowlist-members-open")
      refute has_element?(lv, "#admin-allowlist-members")
      refute has_element?(lv, "#admin-allowlist-restrict-sign-in[checked]")
    end

    test "Add my address and Turn off keep the stored choice", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)
      submit(lv, "203.0.113.0/24", false)

      lv |> element("#admin-allowlist-add-mine") |> render_click()
      refute has_element?(lv, "#admin-allowlist-restrict-sign-in[checked]")

      lv |> element("#admin-allowlist-turn-off") |> render_click()

      row = stored_row(site)
      assert row.cidrs == []
      refute row.restrict_sign_in
    end

    test "an admin demoted while the page is open cannot change it", %{conn: conn, site: site} do
      {admin, membership} = member_of(site, :admin)

      {:ok, lv, _html} =
        conn |> from(site, @me) |> log_in(admin) |> live(~p"/editor/admin-allowlist")

      submit(lv, "203.0.113.0/24")
      Ash.Seed.update!(membership, %{role: :viewer})

      assert submit(lv, "203.0.113.0/24", false) =~ "permission"
      assert stored_row(site).restrict_sign_in == true
    end
  end

  describe "where the page is coming from" do
    test "an address in shared space is warned about", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site, {10, 1, 2, 3})
      assert has_element?(lv, "#admin-allowlist-shared-warning")
    end

    test "a public address is not", %{conn: conn, site: site} do
      {:ok, lv, _html} = open(conn, site)
      refute has_element?(lv, "#admin-allowlist-shared-warning")
    end

    test "an untrusted forwarding header is shown, and a list is refused", %{
      conn: conn,
      site: site
    } do
      restore_env(:trusted_proxies)
      Application.put_env(:kiln_cms, :trusted_proxies, [])

      {:ok, lv, _html} =
        conn
        |> from(site, @me)
        |> put_req_header("x-forwarded-for", "198.51.100.1")
        |> log_in(user_of(site, :admin))
        |> live(~p"/editor/admin-allowlist")

      assert has_element?(lv, "#admin-allowlist-proxy-warning")
      assert has_element?(lv, "#admin-allowlist-save[disabled]")

      html = submit(lv, "203.0.113.0/24")
      assert html =~ "proxy&#39;s address"
      assert stored(site) == nil
    end

    test "on a platform whose sockets never see the client, the save checks the address the page was served to",
         %{conn: conn, site: site} do
      restore_env(:client_ip_header)
      Application.put_env(:kiln_cms, :client_ip_header, {:header, "fly-client-ip"})

      # The socket's peer is the platform's proxy; the client is in the header.
      {:ok, lv, _html} =
        conn
        |> from(site, {172, 16, 0, 9})
        |> put_req_header("fly-client-ip", "203.0.113.70")
        |> log_in(user_of(site, :admin))
        |> live(~p"/editor/admin-allowlist")

      assert has_element?(lv, ".admin-allowlist-address", "203.0.113.70")
      refute has_element?(lv, ".admin-allowlist-address", "172.16.0.9")

      assert submit(lv, "198.51.100.0/24") =~ "current address, 203.0.113.70"
      assert submit(lv, "203.0.113.0/24") =~ "Admin allowlist saved."
    end

    test "the operator's switch is shown", %{conn: conn, site: site} do
      restore_env(:admin_allowlist)
      Application.put_env(:kiln_cms, :admin_allowlist, disabled: true)

      {:ok, lv, _html} = open(conn, site)
      assert has_element?(lv, "#admin-allowlist-disabled", "KILN_ADMIN_ALLOWLIST_DISABLED")
    end
  end
end
