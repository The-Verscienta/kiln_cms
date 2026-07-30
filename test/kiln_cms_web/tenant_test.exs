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

    test "falls back to the default org when the assign is absent" do
      assert Tenant.current_org(%{assigns: %{}}).id == Accounts.default_org_id()
      assert Tenant.current_org(%{}).id == Accounts.default_org_id()
    end
  end
end
