defmodule KilnCMS.Accounts.Checks.PlatformAdmin do
  @moduledoc """
  Matches an actor whose **effective platform role** is `:admin` — a standing
  admin, or one holding a temporary admin grant that has not yet expired.

  Replaces `actor_attribute_equals(:role, :admin)` on the platform resources.
  That check read the `role` field, which
  `KilnCMS.Accounts.Preparations.FoldRoleGrant` sets to the granted tier when the
  actor is *loaded* — so an actor struct that outlives its grant (a LiveView
  socket assigns `current_user` once at mount; `KilnCMSWeb.GraphqlSocket` freezes
  it at connect) kept authorizing as an admin after the grant ran out, for as long
  as the socket lived. This check asks `KilnCMS.Accounts.RoleGrant.effective_role/1`
  instead, which compares `granted_role_expires_at` against the clock at the moment
  of *authorization*: a grant one second past its expiry authorizes as the standing
  tier on a struct that was loaded an hour ago.

  A nil actor never matches.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.RoleGrant

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor's effective platform role is admin"

  @impl Ash.Policy.SimpleCheck
  def match?(nil, _context, _opts), do: false
  def match?(actor, _context, _opts), do: RoleGrant.effective_role(actor) == :admin
end
