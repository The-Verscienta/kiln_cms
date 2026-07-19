defmodule KilnCMS.Accounts.Validations.FieldGrantsShape do
  @moduledoc """
  Validates the shape of a `field_grants` map at write time (granular RBAC
  #332, slice 3): string content-type keys, each mapping to a **list of
  attribute-name strings** (`%{"post" => ["title", "blocks"]}`).

  Without this, an admin typo like `{"post": "title"}` (string instead of
  list) would save fine and then break the grant check on every subsequent
  edit of that type — the failure must land on the admin's write, not the
  editor's.
  """
  use Ash.Resource.Validation

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
        unless Enum.all?(fields, &is_binary/1) do
          error(attribute, "fields for #{inspect(key)} must all be strings")
        end

      {key, _fields} ->
        error(attribute, "#{inspect(key)} must map to a list of field names")
    end)
  end

  defp error(attribute, message), do: {:error, field: attribute, message: message}
end
