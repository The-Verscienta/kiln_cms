defmodule KilnCMS.CMS.Validations.OneFieldScope do
  @moduledoc """
  A `FieldDefinition` belongs to exactly one owner: a compiled content type
  (`content_type` atom), a dynamic one (`type_definition_id`), or a
  `:reference` field it describes the connections of (`link_of_id`, a link
  field — R3). More than one is ambiguous; none is an orphan.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    definition_id = Ash.Changeset.get_attribute(changeset, :type_definition_id)
    link_of = Ash.Changeset.get_attribute(changeset, :link_of_id)

    case {content_type, definition_id, link_of} do
      {nil, nil, nil} ->
        {:error,
         InvalidAttribute.exception(
           field: :content_type,
           message: "a field must belong to a content type or a type definition"
         )}

      {ct, id, nil} when not is_nil(ct) and not is_nil(id) ->
        {:error,
         InvalidAttribute.exception(
           field: :type_definition_id,
           message: "a field cannot belong to both a content type and a type definition"
         )}

      {ct, id, link} when not is_nil(link) and (not is_nil(ct) or not is_nil(id)) ->
        {:error,
         InvalidAttribute.exception(
           field: :link_of_id,
           message: "a link field belongs to its reference field, not directly to a content type"
         )}

      _exactly_one ->
        :ok
    end
  end
end
