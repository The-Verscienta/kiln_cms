defmodule KilnCMSWeb.PerOrgConsoleHostTest do
  @moduledoc """
  One console origin per organization (#1688, decision record 0011).

  With `KILN_CONSOLE_HOST` set, the bare console host is the default org's
  console and `<slug>.<console host>` is every other org's. What these pin:

    * **resolution** — an org's console host resolves to that org, strict or
      not, and the console host itself never resolves as the org whose slug
      is its first label;
    * **routing** — a console route on an org's site redirects to *that org's*
      console host, and no console host serves delivery;
    * **isolation** — no console host is ever an org's site host, so no
      site-served code injection shares an origin with any org's console, and
      the session cookie stays host-only;
    * **passkeys** — ceremonies accept console origins under the unchanged RP
      ID, and never a tenant site's.

  `async: false` — writes `:console_host` and `:tenant_strict_host`
  (VM-global), and clears `KilnCMS.Cache.Hosts`.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.WebAuthn
  alias KilnCMSWeb.Plugs.ConsoleHost
  alias KilnCMSWeb.Tenant

  setup do
    previous = Application.get_env(:kiln_cms, :console_host)
    previous_strict = Application.get_env(:kiln_cms, :tenant_strict_host)

    # Under the base host, as passkeys need — and so that the console host's
    # first label is a valid org slug, which is the collision under test.
    label = "console#{System.unique_integer([:positive])}"
    console = "#{label}.#{Tenant.base_host()}"
    Application.put_env(:kiln_cms, :console_host, console)
    KilnCMS.Cache.Hosts.clear()

    on_exit(fn ->
      restore(:console_host, previous)
      restore(:tenant_strict_host, previous_strict)
      KilnCMS.Cache.Hosts.clear()
    end)

    %{console: console, label: label}
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp site_host(org), do: "#{org.slug}.#{Tenant.base_host()}"
  defp console_host(org, console), do: "#{org.slug}.#{console}"
  defp on(conn, host), do: %{conn | host: host}

  describe "resolution" do
    test "an org's console host resolves to that org, even under TENANT_STRICT_HOST", %{
      console: console
    } do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      a = org("poc-a")

      assert {:ok, %{id: id}} = Tenant.fetch_org(console_host(a, console))
      assert id == a.id

      # Case and a rooted FQDN's trailing dot are the same host.
      assert {:ok, %{id: ^id}} =
               Tenant.fetch_org(String.upcase(console_host(a, console)) <> ".")
    end

    test "the bare console host is the default org's, not the org its first label names", %{
      console: console,
      label: label
    } do
      # An org whose slug is exactly the console host's first label: before
      # #1688 the console host resolved as that org's subdomain.
      Ash.Seed.seed!(Accounts.Organization, %{name: "Clash", slug: label, status: :active})
      default = Accounts.default_org_id()

      assert {:ok, %{id: ^default}} = Tenant.fetch_org(console)
    end

    test "a console host naming no org, or two labels deep, is refused under strict", %{
      console: console
    } do
      Application.put_env(:kiln_cms, :tenant_strict_host, true)
      a = org("poc-deep")

      assert :error = Tenant.fetch_org("nobody-#{System.unique_integer([:positive])}.#{console}")
      assert :error = Tenant.fetch_org("x.#{console_host(a, console)}")
    end

    test "console_host_for/1: bare for the default org, <slug>.<console> for the rest", %{
      console: console
    } do
      a = org("poc-for")

      assert ConsoleHost.console_host_for(a) == console_host(a, console)
      assert ConsoleHost.console_host_for(Accounts.default_org()) == console
      assert ConsoleHost.console_host_for(nil) == console

      Application.delete_env(:kiln_cms, :console_host)
      assert ConsoleHost.console_host_for(a) == nil
    end
  end

  describe "routing" do
    test "a console route on an org's site redirects to that org's console host", %{
      conn: conn,
      console: console
    } do
      a = org("poc-redirect")

      conn = get(on(conn, site_host(a)), "/editor/overview?tab=x")

      assert conn.halted
      target = URI.parse(redirected_to(conn))
      assert target.host == console_host(a, console)
      assert target.path == "/editor/overview"
      assert target.query == "tab=x"
    end

    test "the default org's site still redirects to the bare console host", %{
      conn: conn,
      console: console
    } do
      conn = get(on(conn, Tenant.base_host()), "/editor")
      assert URI.parse(redirected_to(conn)).host == console
    end

    test "an org's console host serves no delivery, and its bare / goes to its own /editor", %{
      conn: conn,
      console: console
    } do
      a = org("poc-delivery")
      host = console_host(a, console)

      assert response(get(on(conn, host), "/some-page"), 404)
      assert response(get(on(conn, host), "/blog"), 404)
      assert response(get(on(conn, host), "/forms/contact/embed"), 404)

      target = URI.parse(redirected_to(get(on(conn, host), "/")))
      assert {target.host, target.path} == {host, "/editor"}
    end

    test "the console is served on an org's console host, under that org", %{
      conn: conn,
      console: console
    } do
      a = org("poc-served")

      conn = get(on(conn, console_host(a, console)), "/editor")

      # Gated — to sign-in on the same host — and resolved to the org, not the
      # default one the console host used to mean.
      assert redirected_to(conn) =~ "/sign-in"
      assert conn.assigns.current_org.id == a.id
    end
  end

  describe "isolation" do
    test "no console host is any org's site host", %{console: console} do
      a = org("poc-isoa")
      b = org("poc-isob", custom_domain: "iso-#{System.unique_integer([:positive])}.example.org")
      default = Accounts.default_org()

      site_hosts =
        for o <- [a, b, default], do: URI.parse(Tenant.base_url(o)).host

      console_hosts = for o <- [a, b, default], do: ConsoleHost.console_host_for(o)

      # One console origin per org…
      assert console_hosts == Enum.uniq(console_hosts)
      assert console == ConsoleHost.console_host_for(default)

      # …none of which is a site origin (where code injection runs), and every
      # one of which is recognised as a console host by the gate.
      for host <- console_hosts do
        refute host in site_hosts
        assert ConsoleHost.console_host_name?(host)
      end

      for host <- site_hosts, do: refute(ConsoleHost.console_host_name?(host))
    end

    test "a console host's session cookie is host-only", %{conn: conn, console: console} do
      a = org("poc-cookie")

      conn = get(on(conn, console_host(a, console)), "/sign-in")
      assert html_response(conn, 200)

      session_cookie =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.find(&String.contains?(&1, "_kiln_cms_key"))

      # No `Domain`: the browser sends it back to this exact host only — never
      # to the org's site, another org's site, or another org's console.
      assert session_cookie
      refute session_cookie =~ ~r/domain=/i
    end
  end

  describe "passkey origins" do
    defp origin_on(host) do
      KilnCMSWeb.Endpoint.struct_url()
      |> Map.merge(%{host: host, path: nil})
      |> URI.to_string()
    end

    defp canonical_origin, do: origin_on(KilnCMSWeb.Endpoint.struct_url().host)

    test "challenges verify origins through origin_allowed?/2" do
      mfa = {WebAuthn, :origin_allowed?, []}

      assert WebAuthn.authentication_challenge().origin_verify_fun == mfa
      assert WebAuthn.registration_challenge().origin_verify_fun == mfa
    end

    test "the canonical origin and every console origin are accepted", %{console: console} do
      a = org("poc-passkey")
      canonical = canonical_origin()

      assert WebAuthn.origin_allowed?(canonical, canonical)
      assert WebAuthn.origin_allowed?(origin_on(console), canonical)
      assert WebAuthn.origin_allowed?(origin_on(console_host(a, console)), canonical)
    end

    test "a tenant site's origin is refused — its code injection could otherwise use one", %{
      console: console
    } do
      a = org("poc-passkeysite")
      canonical = canonical_origin()

      refute WebAuthn.origin_allowed?(origin_on(site_host(a)), canonical)
      refute WebAuthn.origin_allowed?(origin_on("x.#{console_host(a, console)}"), canonical)
    end

    test "a console host on another scheme or port is refused", %{console: console} do
      canonical = canonical_origin()
      url = KilnCMSWeb.Endpoint.struct_url()
      other_scheme = if url.scheme == "https", do: "http", else: "https"

      refute WebAuthn.origin_allowed?("#{other_scheme}://#{console}:#{url.port}", canonical)
      refute WebAuthn.origin_allowed?("#{url.scheme}://#{console}:1337", canonical)
      refute WebAuthn.origin_allowed?(origin_on(console) <> "/path", canonical)
    end

    test "with the gate off, a console origin is just another origin", %{console: console} do
      Application.delete_env(:kiln_cms, :console_host)

      refute WebAuthn.origin_allowed?(origin_on(console), canonical_origin())
    end

    test "passkey_capable?/0 is whether the console host sits under the RP ID" do
      assert ConsoleHost.passkey_capable?()

      Application.put_env(:kiln_cms, :console_host, "console.example.net")
      refute ConsoleHost.passkey_capable?()

      Application.delete_env(:kiln_cms, :console_host)
      assert ConsoleHost.passkey_capable?()
    end
  end
end
