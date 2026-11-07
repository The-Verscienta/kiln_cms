defmodule KilnCMS.CMS.Validations.ReadGrantedStaysPrivate do
  @moduledoc """
  A field named in a role's or membership's `field_read_grants` cannot stop
  being `private` (#2281). The grant hides the field from some editors only
  while it is private; once it is public the restriction would silently stop
  meaning anything. Remove the field from the role (or membership) first.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.ReadGrants

  @impl true
  def validate(changeset, _opts, _context) do
    data = changeset.data

    with true <- data.private == true,
         true <- Ash.Changeset.get_attribute(changeset, :private) == false,
         org_id when is_binary(org_id) <- data.org_id,
         type when is_binary(type) <- ReadGrants.type_name(data, org_id),
         true <- ReadGrants.named?(org_id, type, data.name) do
      {:error,
       field: :private,
       message:
         "can't be turned off while a role or member's read grant for this type names the field"}
    else
      _fine -> :ok
    end
  end
end
