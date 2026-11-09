defmodule KilnCMS.Accounts.Checks.AdminOfMembershipOrg do
  @moduledoc """
  Matches an actor whose effective tier is `:admin` on the organization a
  membership belongs to (#2251) — the registration queue's and its decisions'
  check on `KilnCMS.Accounts.OrgMembership`.

  The org comes from the **row** (`organization_id` on the changeset's data) for
  `:approve_registration` and `:reject_registration`, and from the
  `organization_id` **argument** for the `:registration_queue` read. Never from
  the request's tenant: memberships are global, and the host a request arrives on
  is the client's choice, so an admin of site B asking from any host is still
  refused site A's rows.

  The tier is `KilnCMS.Accounts.Scoping.effective_tier/2`, the one every other
  tier check asks. Anything else — no actor, a system actor, a query without
  the argument — does not match.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping

  @impl Ash.Policy.Check
  def describe(_opts), do: "an admin of the membership's organization"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: subject}, _opts) do
    case org_id(subject) do
      org_id when is_binary(org_id) -> Scoping.effective_tier(actor, org_id) == :admin
      _none -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp org_id(%Ash.Changeset{data: %{organization_id: org_id}}), do: org_id
  defp org_id(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :organization_id)
  defp org_id(_subject), do: nil
end
