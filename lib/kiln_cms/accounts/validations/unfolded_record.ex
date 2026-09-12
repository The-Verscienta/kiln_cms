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

  @impl true
  def validate(changeset, _opts, _context) do
    if RoleGrant.folded?(changeset.data) do
      {:error,
       field: :role,
       message:
         "cannot be written from a record whose temporary role was folded in — " <>
           "re-read it with KilnCMS.Accounts.RoleGrant.unfolded/0"}
    else
      :ok
    end
  end
end
