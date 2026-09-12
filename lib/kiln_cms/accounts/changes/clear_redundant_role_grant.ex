defmodule KilnCMS.Accounts.Changes.ClearRedundantRoleGrant do
  @moduledoc """
  Drops a temporary role grant that the new standing tier has made pointless.

  On `KilnCMS.Accounts.User`'s `:manage_access` and
  `KilnCMS.Accounts.OrgMembership`'s `:update` — the two actions that write a
  standing `role` beside a possibly-live `granted_role`.

  A grant only ever means "for now, treat this person as *more* than their
  standing tier" (`KilnCMS.Accounts.RoleGrant`). Promote a temporary admin to
  permanent admin and the grant no longer says anything: the console would show a
  countdown whose expiry changes nothing, and
  `KilnCMS.Accounts.Validations.TemporaryRoleGrant` would refuse the next edit
  that touched the grant fields, since it is no longer an elevation. So the
  promotion clears it.

  A grant that still outranks the new tier is left alone — demoting someone to
  `:viewer` while they hold "editor until Friday" is a coherent thing to have
  done, and silently revoking the grant would be a second decision the operator
  did not make.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.RoleGrant

  @impl true
  def change(changeset, _opts, _context) do
    granted = Ash.Changeset.get_attribute(changeset, :granted_role)
    # `standing_role/1` rather than `get_attribute(:role)`: on a changeset that
    # doesn't submit a role it falls back to the record's standing tier, which on
    # a folded record is NOT what that field holds.
    role = RoleGrant.standing_role(changeset)

    if not is_nil(granted) and not RoleGrant.elevation?(granted, role) do
      changeset
      |> Ash.Changeset.force_change_attribute(:granted_role, nil)
      |> Ash.Changeset.force_change_attribute(:granted_role_expires_at, nil)
    else
      changeset
    end
  end
end
