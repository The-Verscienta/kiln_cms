defmodule KilnCMSWeb.TenantTest do
  @moduledoc """
  `KilnCMSWeb.Tenant.base_url/1` (#557): every org's own absolute base URL, so
  public URL-building call sites never fall back to the deployment-global host
  on a tenant site.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant

  describe "base_url/1" do
    test "the default org's URL is the global :public_base_url, unchanged" do
      assert Tenant.base_url(Accounts.default_org()) == "http://localhost:4000"
    end

    test "nil resolves to the global :public_base_url (tenant-less callers)" do
      assert Tenant.base_url(nil) == "http://localhost:4000"
    end

    test "an org with only a slug gets <slug>.<base_host>, same scheme/port" do
      o = org("acme")
      assert Tenant.base_url(o) == "http://#{o.slug}.#{Tenant.base_host()}:4000"
    end

    test "an org with a custom domain gets that domain instead of its slug" do
      domain = "www.acme-vanity.com"
      o = org("acme", custom_domain: domain)
      # Same scheme/port as the global config (:4000 in test) — a production
      # deployment's default port (443/https) wouldn't show up in the string.
      assert Tenant.base_url(o) == "http://#{domain}:4000"
    end

    test "accepts a bare org id string, resolving the same as the struct" do
      o = org("byid")
      assert Tenant.base_url(o.id) == Tenant.base_url(o)
    end

    test "an unknown org id falls back to the global default rather than raising" do
      assert Tenant.base_url(Ash.UUID.generate()) == "http://localhost:4000"
    end
  end

  describe "current_org/1" do
    test "reads the :current_org assign off a conn/socket-shaped map" do
      o = org("assign")
      assert Tenant.current_org(%{assigns: %{current_org: o}}).id == o.id
    end

    test "raises when the assign is absent rather than reading the default org" do
      # #563: the old default-org fallback turned a forgotten SetTenant plug or
      # :assign_current_org on_mount into a silent wrong-tenant read in
      # production. Callers that genuinely have no request context are expected
      # to say `Accounts.default_org/0` themselves.
      assert_raise ArgumentError, ~r/without a resolved :current_org assign/, fn ->
        Tenant.current_org(%{assigns: %{}})
      end

      assert_raise ArgumentError, ~r/without a resolved :current_org assign/, fn ->
        Tenant.current_org(%{})
      end

      # Built through `Map.new/1` so the type checker doesn't reject the literal
      # against `current_org/1`'s narrowed head — a `nil` assign is exactly the
      # shape a half-wired caller produces at runtime.
      assert_raise ArgumentError, ~r/without a resolved :current_org assign/, fn ->
        Tenant.current_org_id(Map.new(assigns: %{current_org: nil}))
      end
    end

    test "the message names the assigns present but never dumps the conn" do
      # The message reaches logs and Sentry, and `inspect/1` on a conn prints
      # request headers — Cookie included. It must describe, not dump.
      conn = %{Phoenix.ConnTest.build_conn() | host: "example.test"}
      conn = Plug.Conn.put_req_header(conn, "cookie", "_kiln_key=super-secret")

      error = assert_raise(ArgumentError, fn -> Tenant.current_org(conn) end)
      message = Exception.message(error)

      assert message =~ "assigns are []"
      refute message =~ "super-secret"
      refute message =~ "cookie"
    end
  end
end
