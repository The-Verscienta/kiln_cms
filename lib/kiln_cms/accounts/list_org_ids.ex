defmodule KilnCMS.Accounts.ListOrgIds do
  @moduledoc """
  `AshOban.ListTenants` behaviour returning every organization id (#419,
  strict-tenancy prep).

  AshOban *scheduler* scans on org-scoped resources currently rely on
  `global?: true` (a tenant-less read sees every org's rows). Under strict
  tenancy those scans need explicit tenants — this behaviour makes each
  trigger iterate the orgs, while the worker half keeps running under the
  record's own org (`use_tenant_from_record?`).
  """
  @behaviour AshOban.ListTenants

  @impl AshOban.ListTenants
  def list_tenants(_opts), do: KilnCMS.Accounts.list_org_ids()
end
