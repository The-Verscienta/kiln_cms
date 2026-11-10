defmodule KilnCMS.Accounts.Changes.RaiseRoleByInvitation do
  @moduledoc """
  Raises an active membership to the tier an accepted invitation names
  (`OrgMembership.:raise_role_by_invitation`, #2452), and never lowers it.

  Everything happens in a `before_action` hook, declared **after**
  `get_and_lock_for_update()`, so it judges the row as it is now, locked for
  the rest of the transaction, not the struct the caller read a moment
  earlier (a site admin may have changed the tier in between):

    * a row that is not `:active` is refused as an invitation that is no
      longer valid (`:invalid`): a registration is approved, not raised
      (`:approve_registration_by_invitation`);
    * a row whose **standing** `role` is already the invited tier or higher is
      refused with `:not_higher`, before anything is written. A live temporary
      grant (`granted_role`) is not the standing tier and is not compared:
      it expires, and the invitation is a lasting decision;
    * otherwise `role` is forced to the invited tier, and `role_id` to the
      invitation's custom role when it names one (the row's own is kept when
      it does not). Every other axis (audiences, type scopes, field grants)
      is left as it is. Forced, not set in the change body: the body runs
      against the caller's struct, and Ash drops a change equal to the data
      it was built on.

  `ClearRedundantRoleGrant` is applied here, after the forced write, rather
  than declared on the action: declared, it would run in the change body and
  judge the grant against the tier the row had before.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Changes.ClearRedundantRoleGrant
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.RoleGrant

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &raise_role(&1, context))
  end

  defp raise_role(%{data: %{status: :active, role: standing}} = changeset, context) do
    invited = Ash.Changeset.get_argument(changeset, :role)

    if RoleGrant.elevation?(invited, standing) do
      changeset
      |> Ash.Changeset.force_change_attributes(
        Map.merge(%{role: invited}, custom_role(changeset))
      )
      |> ClearRedundantRoleGrant.change([], context)
    else
      refuse(changeset, :not_higher)
    end
  end

  defp raise_role(changeset, _context), do: refuse(changeset, :invalid)

  defp custom_role(changeset) do
    case Ash.Changeset.get_argument(changeset, :role_id) do
      nil -> %{}
      role_id -> %{role_id: role_id}
    end
  end

  defp refuse(changeset, reason),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvitationRefused.exception(field: :role, reason: reason)
      )
end
