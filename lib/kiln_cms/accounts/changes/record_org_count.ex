defmodule KilnCMS.Accounts.Changes.RecordOrgCount do
  @moduledoc """
  Tell `KilnCMSWeb.Tenant.OrgCount` that an organization was created, so an
  unset `TENANT_STRICT_HOST` turns strict host matching on the moment a second
  organization exists — on every node, with no restart (#1547).

  `after_transaction`, matching only `{:ok, _}`, for the reasons
  `KilnCMS.Accounts.Changes.WarnStrictHostGap` gives: the recount is a database
  read, and a read inside the create's transaction that fails aborts it. There
  is a second reason specific to this one. The verdict it records is read by
  every request, and recording it before the commit would let a concurrent
  request act on an organization that may yet roll back — while a recount on a
  concurrent snapshot could see the pre-create table.

  Declared **before** `WarnStrictHostGap` on the action, and Ash runs
  `after_transaction` hooks in the order they were added: the warning asks the
  effective `strict_host?/0`, which must already reflect this organization, or
  an unset `TENANT_STRICT_HOST` would warn about a gap it just closed.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &record/2)
  end

  defp record(_changeset, {:ok, _org} = result) do
    _ = KilnCMSWeb.Tenant.OrgCount.org_created()
    result
  end

  defp record(_changeset, other), do: other
end
