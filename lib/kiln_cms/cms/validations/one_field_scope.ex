defmodule KilnCMS.CMS.Validations.OneFieldScope do
  @moduledoc """
  A `FieldDefinition` belongs to exactly one owner: a compiled content type
  (`content_type` atom) XOR a dynamic one (`type_definition_id`). Both set is
  ambiguous; neither set is an orphan.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    definition_id = Ash.Changeset.get_attribute(changeset, :type_definition_id)

    case {content_type, definition_id} do
      {nil, nil} ->
        {:error,
         InvalidAttribute.exception(
           field: :content_type,
           message: "a field must belong to a content type or a type definition"
         )}

      {ct, id} when not is_nil(ct) and not is_nil(id) ->
        {:error,
         InvalidAttribute.exception(
           field: :type_definition_id,
           message: "a field cannot belong to both a content type and a type definition"
         )}

      _exactly_one ->
        :ok
    end
  end
end
