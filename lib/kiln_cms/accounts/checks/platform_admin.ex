defmodule KilnCMS.Accounts.Checks.PlatformAdmin do
  @moduledoc """
  Matches an actor whose **effective platform role** is `:admin` — a standing
  admin, or one holding a temporary admin grant that has not yet expired.

  Replaces `actor_attribute_equals(:role, :admin)` on the platform resources.
  `role` is the standing tier only, so that check could not see a grant at all;
  and any value computed when the actor was *loaded* would outlive the grant on a
  long-lived struct (a LiveView socket assigns `current_user` once at mount;
  `KilnCMSWeb.GraphqlSocket` freezes it at connect). This check asks
  `KilnCMS.Accounts.RoleGrant.effective_role/1`, which compares
  `granted_role_expires_at` against the clock at the moment of *authorization*: a
  grant one second past its expiry authorizes as the standing tier on a struct
  that was loaded an hour ago.

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
