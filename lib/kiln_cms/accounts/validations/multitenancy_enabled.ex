defmodule KilnCMS.Accounts.Validations.MultitenancyEnabled do
  @moduledoc """
  Refuses to provision a new organization while multi-tenant delivery is off
  (`config :kiln_cms, :multitenancy_enabled, false` — the default).

  Epic #336 rolls out the tenant axis in stages: PR 1 adds `org_id` in non-strict
  mode (`global?: true`), where a tenant-less delivery read applies **no** `org_id`
  filter and the public GraphQL/JSON:API/artifact reads carry no tenant yet. In
  that state a *single* organization (the seeded default) is safe — every read is
  effectively scoped to it — but a **second** org would be silently spanned by
  every tenant-less read, leaking one site's content on another's host. This guard
  makes the "one org until the delivery path threads a tenant" invariant an
  enforced precondition instead of a convention: the flag is flipped on only once
  the routing/tenant-resolution PR ships. The seeded default org is created by the
  backfill migration (which bypasses this action), so bootstrapping is unaffected.
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
