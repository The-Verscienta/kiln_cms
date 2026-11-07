defmodule KilnCMS.Accounts.Validations.FieldGrantsShape do
  @moduledoc """
  Validates the shape of a `field_grants` map at write time (granular RBAC
  #332, slice 3): string content-type keys, each mapping to a **list of
  attribute-name strings** (`%{"post" => ["title", "blocks"]}`).

  Without this, an admin typo like `{"post": "title"}` (string instead of
  list) would save fine and then break the grant check on every subsequent
  edit of that type — the failure must land on the admin's write, not the
  editor's.

  `custom_fields...` entries (#2281) are checked for syntax too — the bare
  `custom_fields`, `custom_fields.<name>`, `custom_fields.<group>.<sub>`
  (`KilnCMS.CMS.FieldAccess`) — so a typo like `custom_fields.Name` fails on
  the admin's write instead of silently granting nothing. Whether the name is a
  real field is not checked: a stale name is shown as "(not found)" by the
  pickers. For `attribute: :field_read_grants` only the bare key and
  `custom_fields.<name>` are legal. (That the name is a *private* field needs
  the definitions, so the pickers and the guard on `FieldDefinition` hold it.)
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.FieldAccess

  @impl true
  def validate(changeset, opts, _context) do
    attribute = Keyword.get(opts, :attribute, :field_grants)

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> :ok
      grants when is_map(grants) -> validate_entries(grants, attribute)
      _other -> error(attribute, "must be a map of content type to field lists")
    end
  end

  defp validate_entries(grants, attribute) do
    Enum.find_value(grants, :ok, fn
      {key, fields} when is_binary(key) and is_list(fields) ->
        cond do
          not Enum.all?(fields, &is_binary/1) ->
            error(attribute, "fields for #{inspect(key)} must all be strings")

          bad = Enum.find(fields, &(not legal_entry?(attribute, &1))) ->
            error(attribute, "#{inspect(bad)} is not a valid field name for #{inspect(key)}")

          true ->
            nil
        end

      {key, _fields} ->
        error(attribute, "#{inspect(key)} must map to a list of field names")
    end)
  end

  defp legal_entry?(:field_read_grants, entry), do: FieldAccess.read_entry_shape?(entry)
  defp legal_entry?(_attribute, entry), do: FieldAccess.parse(entry) != :invalid

  defp error(attribute, message), do: {:error, field: attribute, message: message}
end
