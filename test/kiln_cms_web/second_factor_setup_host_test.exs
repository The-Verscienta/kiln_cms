defmodule KilnCMSWeb.SecondFactorSetupHostTest do
  @moduledoc """
  Where the two-step setup page is served (#2247, owner decision of
  2026-11-13): on the main host and console hosts only. On a tenant site host
  `/account/two-factor` is a redirect to the main host's page, over HTTP and
  LiveView, signed in or not, and every door that sends a held account to set
  up a factor sends it there too; `/account` and the grace banner on a site
  host link there. Where the page is served, it renders, a held account goes
  to it with `return_to`, and following the redirect never loops.

  `async: false`: the console host is `Application.put_env`, VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures
  import Phoenix.LiveViewTest

  alias KilnCMSWeb.SecondFactorGate

  @moduletag :capture_log

  @password "password123456"
  @setup "/account/two-factor"

  # What only the page's factor management draws.
  @factor_ui ~w(two-factor-app start-totp add-passkey-form two-factor-proof)

  setup do
    with_console_host()
  end

  defp main_setup, do: SecondFactorGate.main_setup_url()
  defp main_host, do: URI.parse(KilnCMSWeb.Endpoint.url()).host
  defp console, do: KilnCMSWeb.Plugs.ConsoleHost.console_host()
  defp on(conn, host), do: %{conn | host: host}

  defp refute_factor_ui(html) do
    for id <- @factor_ui, do: refute(html =~ ~s(id="#{id}"), id)
  end

  describe "setup_host?/1" do
    test "the main host and console hosts, never a site host" do
      site = org("sfsh-pred")

      assert SecondFactorGate.setup_host?(main_host())
      assert SecondFactorGate.setup_host?(String.upcase(main_host()) <> ".")
      assert SecondFactorGate.setup_host?(console())
      assert SecondFactorGate.setup_host?("#{site.slug}.#{console()}")

      refute SecondFactorGate.setup_host?("#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}")
      refute SecondFactorGate.setup_host?("www.example.com")
      refute SecondFactorGate.setup_host?(nil)
    end
  end

  describe "the page on a site host" do
    test "is a 302 to the main host's page, signed in or not, with no factor UI", %{conn: conn} do
      site = org("sfsh-http")
      user = viewer(site)

      for conn <- [org_conn(conn, site), signed_in(conn, user, site)],
          path <- [@setup, @setup <> "?return_to=/membership&reminder=1"] do
        redirected = get(conn, path)

        assert redirected_to(redirected) == main_setup(), path
        refute_factor_ui(response(redirected, 302))
      end
    end

    test "a LiveView mount, and a live navigation from /account, go to the main host", %{
      conn: conn
    } do
      site = org("sfsh-lv")
      conn = signed_in(conn, viewer(site), site)

      assert {:error, {:redirect, %{to: to}}} = live(conn, @setup)
      assert to == main_setup()

      {:ok, account, _html} = live(conn, ~p"/account")
      assert {:error, {:redirect, %{to: to}}} = live_redirect(account, to: @setup)
      assert to == main_setup()
    end
  end

  describe "where the page is served" do
    test "the main host renders it, and the site host's redirect does not loop", %{conn: conn} do
      site = org("sfsh-main")
      user = viewer(site)

      # The redirect names the main host; following it lands on the page.
      %URI{host: host, path: path} = URI.parse(main_setup())
      assert host == main_host()

      on_main = conn |> signed_in(user, site) |> on(host)
      html = on_main |> get(path) |> html_response(200)
      assert html =~ ~s(id="two-factor-app")

      {:ok, view, _html} = live(on_main, path)
      assert has_element?(view, "#two-factor-app")

      # Signed out there: its own sign-in, not another trip.
      assert redirected_to(conn |> on(host) |> get(path)) == ~p"/sign-in"
    end

    test "the bare console host and an org's console host render it", %{conn: conn} do
      site = org("sfsh-console")
      user = viewer(site)

      for host <- [console(), "#{site.slug}.#{console()}"] do
        assert conn |> signed_in(user, site) |> on(host) |> get(@setup) |> html_response(200) =~
                 ~s(id="two-factor-app"),
               host
      end
    end
  end

  describe "a held account" do
    test "on a site host goes to the main host's page: absolute, no return_to, no-store", %{
      conn: conn
    } do
      site = "sfsh-held" |> org() |> tap(&policy_row!(&1, :editors))
      conn = signed_in(conn, editor(site), site)

      # Not a console route: those go to the console host first.
      for path <- [~p"/account", ~p"/membership", "/some-page"] do
        held = get(conn, path)

        assert redirected_to(held) == main_setup(), path
        assert get_resp_header(held, "cache-control") == ["private, no-store"]
        refute_factor_ui(response(held, 302))
      end
    end

    test "on its console host goes to the page there with return_to, which then renders", %{
      conn: conn
    } do
      site = "sfsh-held-console" |> org() |> tap(&policy_row!(&1, :editors))
      conn = conn |> signed_in(editor(site), site) |> on("#{site.slug}.#{console()}")

      held = get(conn, ~p"/editor/overview")

      assert redirected_to(held) ==
               @setup <> "?" <> URI.encode_query(%{"return_to" => "/editor/overview"})

      assert get_resp_header(held, "cache-control") == ["private, no-store"]

      # No loop: the page itself is served to the held account.
      assert conn |> get(redirected_to(held)) |> html_response(200) =~ ~s(id="two-factor-app")
    end

    test "the LiveView gate keeps the local page on a console host, not on a site host" do
      site = "sfsh-held-lv" |> org() |> tap(&policy_row!(&1, :editors))

      socket = fn host ->
        %Phoenix.LiveView.Socket{
          view: KilnCMSWeb.OverviewLive,
          host_uri: URI.parse("http://#{host}"),
          assigns: %{__changed__: %{}, current_user: editor(site), current_org: site}
        }
      end

      assert {:halt, held} = SecondFactorGate.attach(socket.("#{site.slug}.#{console()}"), %{})
      assert {:redirect, %{to: @setup}} = held.redirected

      on_site = socket.("#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}")
      assert {:halt, held} = SecondFactorGate.attach(on_site, %{})
      assert {:redirect, %{external: external}} = held.redirected
      assert external == main_setup()
    end

    test "a password sign-in on a site host lands on the main host's page; on a console host, here",
         %{conn: conn} do
      site = "sfsh-door" |> org() |> tap(&policy_row!(&1, :editors))
      user = editor(site)

      sign_in = fn host ->
        conn
        |> on(host)
        |> Phoenix.ConnTest.init_test_session(%{})
        |> post(~p"/auth/user/password/sign_in", %{
          "user" => %{"email" => to_string(user.email), "password" => @password}
        })
      end

      on_site = sign_in.("#{site.slug}.#{KilnCMSWeb.Tenant.base_host()}")
      assert redirected_to(on_site) == main_setup()

      on_console = sign_in.("#{site.slug}.#{console()}")
      assert redirected_to(on_console) =~ @setup <> "?return_to="
    end
  end

  describe "/account" do
    test "on a site host links to the main host's page, and says so", %{conn: conn} do
      site = org("sfsh-account")
      {:ok, view, _html} = conn |> signed_in(viewer(site), site) |> live(~p"/account")

      assert has_element?(view, ~s(#two-factor-setup-link[href="#{main_setup()}"]))
      assert render(view) =~ "This opens on #{main_host()}, where you sign in again."
      refute_factor_ui(render(view))
    end

    test "on the main host and a console host links the page here", %{conn: conn} do
      site = org("sfsh-account-here")
      user = viewer(site)

      for host <- [main_host(), "#{site.slug}.#{console()}"] do
        {:ok, view, html} = conn |> signed_in(user, site) |> on(host) |> live(~p"/account")

        assert has_element?(view, ~s(#two-factor-setup-link[href="#{@setup}"])), host
        refute html =~ "where you sign in again", host
      end
    end

    test "the grace banner on a site host links to the main host's page", %{conn: conn} do
      site =
        "sfsh-banner"
        |> org()
        |> tap(&policy_row!(&1, :everyone, grace_days: 30, since: DateTime.utc_now()))

      {:ok, view, _html} = conn |> signed_in(viewer(site), site) |> live(~p"/account")

      assert has_element?(view, ~s(#second-factor-banner-link[href="#{main_setup()}"]))
    end
  end
end
