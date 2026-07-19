defmodule KilnCMS.Accounts.Validations.RoleBelongsToOrg do
  @moduledoc """
  A membership's custom role must belong to the membership's own organization
  (granular RBAC #332, slice 4).

  `role_id` is client-supplied (the team UI's select), so without this check a
  crafted submit could bind an org-A membership to org-B's role bundle —
  applying a foreign org's scope axes, editable at any time by that org's
  admins.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Accounts

  @impl true
  def validate(changeset, _opts, _context) do
    role_id = Ash.Changeset.get_attribute(changeset, :role_id)
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
    Accounts.get_role(role_id, authorize?: false, not_found_error?: false)
  end
end
