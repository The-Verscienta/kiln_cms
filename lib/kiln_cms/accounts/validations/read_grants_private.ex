defmodule KilnCMS.Accounts.Validations.ReadGrantsPrivate do
  @moduledoc """
  A `field_read_grants` entry may only name a **private** custom field (#2281).

  A read restriction hides a private field from some editors; a field that is
  not private is world-readable on published content, so restricting it would
  promise a privacy it cannot deliver. `FieldGrantsShape` checks the syntax;
  this checks the entries against the site's definitions
  (`KilnCMS.CMS.ReadGrants.invalid_entries/2`). A name no field has passes (the
  pickers show it as "not found"). Runs only when the grant is being changed,
  so an untouched save never trips over an older value.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.ReadGrants

  @impl true
  def validate(changeset, _opts, _context) do
    with true <- Ash.Changeset.changing_attribute?(changeset, :field_read_grants),
         grants when is_map(grants) <-
           Ash.Changeset.get_attribute(changeset, :field_read_grants),
         org_id when is_binary(org_id) <- org_id(changeset),
         [{type, entry} | _] <- ReadGrants.invalid_entries(grants, org_id) do
      {:error,
       field: :field_read_grants,
       message: "#{inspect(entry)} is not a private custom field of #{inspect(type)}"}
    else
      _fine -> :ok
    end
  end

  defp org_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :org_id) ||
      Ash.Changeset.get_attribute(changeset, :organization_id)
  end
end
