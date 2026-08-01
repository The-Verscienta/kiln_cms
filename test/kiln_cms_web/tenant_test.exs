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

    # #563: this used to return the default org, so any code path that forgot the
    # assign read the default org's content instead of failing — invisible on a
    # single-org install and a cross-tenant read on a multi-org one.
    test "raises when the assign is absent, rather than defaulting" do
      assert_raise ArgumentError, ~r/without a :current_org assign/, fn ->
        Tenant.current_org(%{assigns: %{}})
      end

      assert_raise ArgumentError, ~r/without a :current_org assign/, fn ->
        Tenant.current_org(%{})
      end
    end

    # A nil assign is the same bug wearing a different hat — SetTenant assigning
    # `nil` would otherwise satisfy "the assign is present" and crash later.
    test "raises when the assign is present but nil" do
      assert_raise ArgumentError, ~r/without a :current_org assign/, fn ->
        Tenant.current_org(%{assigns: %{current_org: nil}})
      end
    end

    # The exception is logged and may reach Sentry, so it must not carry session
    # data, request bodies or user records out with it.
    test "the raise reports the shape of its argument, not the contents" do
      conn = %Plug.Conn{host: "acme.test", private: %{secret: "s3kr1t"}}

      error = assert_raise(ArgumentError, fn -> Tenant.current_org(conn) end)

      assert error.message =~ "acme.test"
      refute error.message =~ "s3kr1t"
    end
  end

  describe "current_org_or_default/1" do
    test "reads the assign when present" do
      o = org("explicit-default")
      assert Tenant.current_org_or_default(%{assigns: %{current_org: o}}).id == o.id
    end

    # The explicit opt-in to what current_org/1 used to do implicitly.
    test "falls back to the default org when the assign is absent" do
      assert Tenant.current_org_or_default(%{assigns: %{}}).id == Accounts.default_org_id()
      assert Tenant.current_org_or_default(%{}).id == Accounts.default_org_id()
      assert Tenant.current_org_id_or_default(%{}) == Accounts.default_org_id()
    end
  end
end
