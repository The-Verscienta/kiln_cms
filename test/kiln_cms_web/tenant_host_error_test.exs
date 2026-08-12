defmodule KilnCMSWeb.TenantHostErrorTest do
  @moduledoc """
  `Tenant.fetch_org/1` must tell a genuine "no such host" from a failed read
  (#1124) — collapsing both to the same outcome is what let one `Ash.Error.
  Invalid`-wrapped `NotFound` (the normal shape for a `get_by:` miss, not an
  error at all) 404 every request whose host isn't a known org's, since
  `Accounts.default_org/0` and `lookup/2` both go through the very same
  `get_by:` code interface (#1124's own regression, caught before it merged).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMSWeb.Tenant

  test "an unrecognized host still resolves to the default org, not :error" do
    # Phoenix's own build_conn/0 default host, and not `Tenant.base_host/0` —
    # exactly the shape that tripped the regression: a host that names no
    # organization by slug or custom domain.
    assert {:ok, %KilnCMS.Accounts.Organization{}} = Tenant.fetch_org("www.example.com")
  end

  test "the base host resolves to the seeded default org" do
    assert {:ok, %KilnCMS.Accounts.Organization{id: id}} = Tenant.fetch_org(Tenant.base_host())
    assert id == KilnCMS.Accounts.default_org_id()
  end

  test "resolve_org/1 never raises on an unrecognized host" do
    assert %KilnCMS.Accounts.Organization{} = Tenant.resolve_org("no-such-org.invalid")
  end
end
