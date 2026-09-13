defmodule KilnCMS.Accounts.Validations.StandingAdminOnly do
  @moduledoc """
  Refuses a tier-granting write from an actor who is an admin only *temporarily*.

  A temporary admin grant (`KilnCMS.Accounts.RoleGrant`) is meant to be bounded.
  But everything it authorizes is decided by the actor's *effective* role, and the
  actions that grant tiers are among those things — so without this, a grantee
  could write `role: :admin` onto their own account, or grant themselves another
  thirty days, and the bound would last exactly as long as they chose. The design
  exists to avoid "a 48-hour admin is an admin forever"; this is the rule that
  makes it true.

  Declared on the actions that confer or extend a tier:
  `KilnCMS.Accounts.User`'s `:manage_access` and `:grant_temporary_role`, and
  every create/update on `KilnCMS.Accounts.OrgMembership` (a temporary platform
  admin making themselves a site admin would keep that tier after the platform
  grant lapsed). Ordinary admin work a grantee was trusted with — resetting a
  password, signing someone out, removing an account — is untouched.

  A validation rather than a policy check, for the reason
  `KilnCMS.Accounts.Validations.NotLastAdmin` gives: both resources open with an
  admin *bypass*, and a bypass that passes short-circuits every policy after it,
  so a `forbid_if` here would never run for exactly the actor it is aimed at.

  A call with no actor is a system call (`KilnCMS.Billing.Entitlements`, the
  release console, a seed) and passes: the rule is about who is *acting*, and a
  system call is not a grantee.

  ## Only the grantee

  It fires for exactly one kind of actor: an **effective** admin who is not a
  **standing** one. Everyone else passes through to the policies. A validation
  runs while the changeset is built — before authorization — so refusing a plain
  editor here would turn the policy's `Forbidden` into an `Invalid` that explains
  the grant rules to someone who was never going to be allowed near them.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.RoleGrant

  @impl true
  def validate(_changeset, _opts, %{actor: nil}), do: :ok

  def validate(_changeset, _opts, %{actor: actor}) do
    grantee? =
      RoleGrant.effective_role(actor) == :admin and RoleGrant.standing_role(actor) != :admin

    if grantee? do
      {:error,
       field: :role,
       message:
         "can only be granted by a standing admin — a temporary admin cannot grant or extend a tier"}
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context), do: :ok
end
