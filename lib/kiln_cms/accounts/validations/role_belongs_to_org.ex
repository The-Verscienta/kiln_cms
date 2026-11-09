defmodule KilnCMS.Accounts.Validations.RoleBelongsToOrg do
  @moduledoc """
  A membership's custom role must belong to the membership's own organization
  (granular RBAC #332, slice 4).

  `role_id` is client-supplied (the team UI's select), so without this check a
  crafted submit could bind an org-A membership to org-B's role bundle —
  applying a foreign org's scope axes, editable at any time by that org's
  admins.

  `argument: name` checks that argument instead of the `role_id` attribute,
  for an action that writes the role in a hook after validations have run
  (`OrgMembership.:approve_registration_by_invitation`, #2514). The org is the
  row's own either way.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts

  @impl true
  def validate(changeset, opts, _context) do
    role_id =
      case Keyword.get(opts, :argument) do
        nil -> Ash.Changeset.get_attribute(changeset, :role_id)
        argument -> Ash.Changeset.get_argument(changeset, argument)
      end

    org_id = Ash.Changeset.get_attribute(changeset, :organization_id)

    cond do
      is_nil(role_id) ->
        :ok

      match?({:ok, %{org_id: ^org_id}}, get_role(role_id)) ->
        :ok

      true ->
        {:error, field: :role_id, message: "must be a role of this organization"}
    end
  end

  defp get_role(role_id) do
    # authorize?: false — a validation must see the role as stored, whoever is
    # acting (validations run before policies, with any actor or none). It only
    # ever refuses: a miss fails the write, so a bypass cannot fail open here.
    Accounts.get_role(role_id, authorize?: false, not_found_error?: false)
  end
end
