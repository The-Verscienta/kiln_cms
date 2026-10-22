defmodule KilnCMS.CMS.Validations.OneFieldScope do
  @moduledoc """
  A `FieldDefinition` belongs to exactly one owner: a compiled content type
  (`content_type` atom), a dynamic one (`type_definition_id`), a `:reference`
  field it describes the connections of (`link_of_id`, a link field — R3), or
  a `:group` field whose rows it is one key of (`group_of_id`, a sub-field).
  More than one is ambiguous; none is an orphan.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    definition_id = Ash.Changeset.get_attribute(changeset, :type_definition_id)
    link_of = Ash.Changeset.get_attribute(changeset, :link_of_id)
    group_of = Ash.Changeset.get_attribute(changeset, :group_of_id)

    case {content_type, definition_id, link_of, group_of} do
      {nil, nil, nil, nil} ->
        error(:content_type, "a field must belong to a content type or a type definition")

      {_ct, _id, link, group} when not is_nil(link) and not is_nil(group) ->
        error(:group_of_id, "a field cannot be both a link field and a group's sub-field")

      {ct, id, nil, nil} when not is_nil(ct) and not is_nil(id) ->
        error(
          :type_definition_id,
          "a field cannot belong to both a content type and a type definition"
        )

      {ct, id, link, nil} when not is_nil(link) and (not is_nil(ct) or not is_nil(id)) ->
        error(
          :link_of_id,
          "a link field belongs to its reference field, not directly to a content type"
        )

      {ct, id, nil, group} when not is_nil(group) and (not is_nil(ct) or not is_nil(id)) ->
        error(:group_of_id, "a sub-field belongs to its group, not directly to a content type")

      _exactly_one ->
        :ok
    end
  end

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
