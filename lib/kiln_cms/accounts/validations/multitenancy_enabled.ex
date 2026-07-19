defmodule KilnCMS.Accounts.Validations.MultitenancyEnabled do
  @moduledoc """
  A kill switch for provisioning new organizations
  (`config :kiln_cms, :multitenancy_enabled` — **`true` by default**).

  Epic #336 rolled out the tenant axis in stages: every per-site resource carries
  `org_id`, and every delivery/editor/API/worker read threads the request's tenant
  (the `SetTenant` plug scopes the headless GraphQL/JSON:API surfaces; a pre-lift
  cross-org audit verified the manual reads). With the tenant fully threaded, a
  second organization is served in isolation by host, so this guard now defaults
  to **allowing** org creation.

  A single-tenant install can flip the flag to `false` to hard-refuse a second
  org. The seeded default org is created by the backfill migration (which bypasses
  this action), so bootstrapping is unaffected either way.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(_changeset, _opts, _context) do
    if Application.get_env(:kiln_cms, :multitenancy_enabled, false) do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :slug,
         message:
           "multi-tenancy is not enabled — additional organizations cannot be created " <>
             "until the delivery path threads the tenant (set :multitenancy_enabled)"
       )}
    end
  end
end
