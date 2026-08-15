defmodule KilnCMSWeb.Plugs.ConsoleHostTest do
  @moduledoc """
  The console/delivery origin split (#740, step 2), through the real endpoint:
  with `KILN_CONSOLE_HOST` set, console routes are served only there, tenant
  content never is, and shared routes on both. Off, nothing changes.

  `async: false` — sets `:console_host` and `:tenant_strict_host` (VM-global).
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMSWeb.Plugs.ConsoleHost
  alias KilnCMSWeb.Tenant

  @console "console.example.test"

  setup do
    previous = Application.get_env(:kiln_cms, :console_host)
    previous_strict = Application.get_env(:kiln_cms, :tenant_strict_host)

    on_exit(fn ->
      restore(:console_host, previous)
      restore(:tenant_strict_host, previous_strict)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp on_console(conn), do: %{conn | host: @console}
  defp on_site(conn), do: %{conn | host: "www.example.com"}

  describe "off (the default)" do
    test "console and delivery are served on the same host as before", %{conn: conn} do
      Application.delete_env(:kiln_cms, :console_host)
      refute ConsoleHost.console_host()

      # /editor redirects to sign-in (the console is there, just gated).
      assert redirected_to(get(on_site(conn), "/editor")) =~ "/sign-in"
      # And the site home renders.
      assert html_response(get(on_site(conn), "/"), 200)
    end
  end

  describe "on" do
    setup do
      Application.put_env(:kiln_cms, :console_host, " Console.Example.Test ")
      :ok
    end

    test "the host is normalized" do
      assert ConsoleHost.console_host() == @console
    end

    test "a console route on a tenant host redirects a GET to the console host, same path and query",
         %{conn: conn} do
      conn = get(on_site(conn), "/editor/overview?tab=x")
      assert conn.status == 302
      # Scheme and port are the endpoint's (the test endpoint's :4000), host swapped.
      assert redirected_to(conn) == ConsoleHost.console_url("/editor/overview?tab=x")

      assert redirected_to(conn) =~
               ~r{^http://console\.example\.test(:\d+)?/editor/overview\?tab=x$}

      # The gate ran ahead of the router: no console response body left this host.
      assert conn.halted
    end

    test "a console route on a tenant host that is not a GET is a 404", %{conn: conn} do
      conn =
        on_site(conn)
        |> put_req_header("content-type", "application/json")
        |> post("/editor/overview", "{}")

      assert response(conn, 404)
    end

    test "tenant content on the console host is a 404; the bare host goes to /editor", %{
      conn: conn
    } do
      assert response(get(on_console(conn), "/blog"), 404)
      assert response(get(on_console(conn), "/some-page"), 404)
      assert response(get(on_console(conn), "/forms/contact/embed"), 404)

      conn = get(on_console(conn), "/")
      assert redirected_to(conn) =~ ~r{^http://console\.example\.test(:\d+)?/editor$}
    end

    test "console routes are served on the console host", %{conn: conn} do
      # Gated, so a redirect to sign-in — which is on the console host too.
      conn = get(on_console(conn), "/editor")
      assert redirected_to(conn) =~ "/sign-in"
    end

    test "shared routes are served on both hosts", %{conn: conn} do
      # The sign-in page renders on the site (a member's) and on the console.
      assert html_response(get(on_site(conn), "/sign-in"), 200)
      assert html_response(get(on_console(conn), "/sign-in"), 200)

      # The health probe answers on both.
      assert get(on_site(conn), "/up").status in [200, 503]
      assert get(on_console(conn), "/up").status in [200, 503]
    end

    test "the console host resolves to the default org, even under TENANT_STRICT_HOST" do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      default = KilnCMS.Accounts.default_org_id()

      assert {:ok, %{id: ^default}} = Tenant.fetch_org(@console)
      # …while an unknown host is still refused under strict.
      assert :error = Tenant.fetch_org("nobody.example.test")
    end

    test "console_url/1 keeps the endpoint's scheme and port" do
      url = ConsoleHost.console_url("/editor")
      assert String.starts_with?(url, "http://#{@console}")
      assert String.ends_with?(url, "/editor")
    end
  end
end
