defmodule KilnCMS.Accounts.Validations.UnfoldedRecord do
  @moduledoc """
  Refuses an update whose base record came back with a temporary role folded in.

  `KilnCMS.Accounts.Preparations.FoldRoleGrant` presents a live grant as `role`
  on every read, which is what makes the grant enforce itself against every
  policy. A record read that way is the wrong base for a *write* of `role`, and
  wrong in the silent direction — Ash discards a submitted attribute that equals
  `changeset.data` at cast time, so `role: :admin` on a folded temporary admin is
  dropped as a no-op and the standing column never moves. That module's moduledoc
  has the worked example.

  The rule is one line at the call site (read with
  `KilnCMS.Accounts.RoleGrant.unfolded/0`), so this exists only to make breaking
  it loud. Without it the next surface that lists users and offers a role select —
  a plugin panel, a bulk action, an AshAdmin form — inherits a bug that no test
  of its own would catch, because the action reports success.

  Declared on the actions that write a standing `role`:
  `KilnCMS.Accounts.User`'s `:manage_access` and
  `KilnCMS.Accounts.OrgMembership`'s `:update`. Not on the grant actions
  themselves — they never touch `role`, so a folded base is harmless there, and
  `KilnCMS.Accounts.RoleGrant.standing_role/1` recovers the baseline they compare
  against from the metadata.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts.RoleGrant

  # Only when `role` was SUBMITTED. The hazard is specific to a write that submits
  # `role` — that is the attribute Ash drops as equal to the folded value. An
  # update that never mentions it (`KilnCMS.Billing.Entitlements` writing only
  # `audiences` on a membership) builds on a folded record harmlessly, and
  # refusing it silently broke entitlement sync for anyone holding a live grant.
  #
  # The test is on the submitted params, not on `changing_attribute?/2`: a dropped
  # `role` is precisely a role that is *not* changing, so "is it changing" would
  # wave through the one write this exists to stop.
  @impl true
  def validate(changeset, _opts, _context) do
    if RoleGrant.folded?(changeset.data) and role_submitted?(changeset) do
      {:error,
       field: :role,
       message:
         "cannot be written from a record whose temporary role was folded in — " <>
           "re-read it with KilnCMS.Accounts.RoleGrant.unfolded/0"}
    else
      :ok
    end
  end

  defp role_submitted?(%{params: params}) when is_map(params),
    do: Map.has_key?(params, :role) or Map.has_key?(params, "role")

  defp role_submitted?(_changeset), do: false
end
