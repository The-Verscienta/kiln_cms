defmodule KilnCMS.CMS.Checks.InAudience do
  @moduledoc """
  Authorizes published content whose `audience` the actor holds **on the request's
  organization** (#337 Phase 2).

  Replaces the previous inline grant, which read `^actor(:audiences)` off the
  global `KilnCMS.Accounts.User` column. That column is instance-wide while
  `KilnCMS.Billing.Membership` is org-scoped, so on a multi-org instance paying
  for a membership on one site widened access on every other site. Resolution now
  goes through `KilnCMS.Accounts.Scoping.audiences/2`, which reads the per-org
  `OrgMembership` value and is fail-closed for a foreign org.

  ## A FilterCheck, not a SimpleCheck

  The audience grant has always been a **per-record** decision — a query returns
  the rows whose audience the reader holds, not all-or-nothing. A `SimpleCheck`
  would authorize the entire query or none of it, which for a list read would
  either leak every gated row or hide every public one.

  Returning `false` for an actor with no audiences (rather than an expression that
  matches nothing) keeps the generated SQL clean; the sibling `:public` grant in
  the policy is what admits ordinary published content.
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.Accounts.Scoping

  @impl true
  def describe(_opts), do: "content whose audience the actor holds on this org"

  @impl true
  def filter(actor, context, _opts) do
    # `context` is the `Ash.Policy.Authorizer` STRUCT, not an Access-able map, so
    # `context[:subject]` raises. `Map.get/3` also tolerates the plain-map shape
    # other check callbacks receive.
    case Scoping.audiences(actor, Map.get(context, :subject)) do
      [] -> false
      audiences -> expr(state == :published and audience in ^audiences)
    end
  end
end
