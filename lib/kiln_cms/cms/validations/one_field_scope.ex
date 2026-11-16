defmodule KilnCMS.CMS.Validations.OneFieldScope do
  @moduledoc """
  A `FieldDefinition` belongs to exactly one owner: a compiled content type
  (`content_type` atom), a dynamic one (`type_definition_id`), a `:reference`
  field it describes the connections of (`link_of_id`, a link field — R3), or
  a `:group` field whose rows it is one key of (`group_of_id`, a sub-field), or
  a `:flexible` field it is one item type of (`flex_of_id`, #2282). More than
  one is ambiguous; none is an orphan.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @owners [:content_type, :type_definition_id, :link_of_id, :group_of_id, :flex_of_id]
  @parents [:link_of_id, :group_of_id, :flex_of_id]

  @impl true
  def validate(changeset, _opts, _context) do
    owners = Enum.reject(@owners, &is_nil(Ash.Changeset.get_attribute(changeset, &1)))

    case owners do
      [] -> error(:content_type, "a field must belong to a content type or a type definition")
      [_exactly_one] -> :ok
      several -> conflict(several)
    end
  end

  defp conflict(owners) do
    cond do
      match?([_, _ | _], Enum.filter(@parents, &(&1 in owners))) ->
        both_parents(Enum.filter(@parents, &(&1 in owners)))

      :link_of_id in owners ->
        error(
          :link_of_id,
          "a link field belongs to its reference field, not directly to a content type"
        )

      :group_of_id in owners ->
        error(:group_of_id, "a sub-field belongs to its group, not directly to a content type")

      :flex_of_id in owners ->
        error(
          :flex_of_id,
          "an item type belongs to its flexible field, not directly to a content type"
        )

      true ->
        error(
          :type_definition_id,
          "a field cannot belong to both a content type and a type definition"
        )
    end
  end

  # A field hangs off one parent field at most: a reference, a group or a
  # flexible field.
  defp both_parents([:link_of_id, :group_of_id]),
    do: error(:group_of_id, "a field cannot be both a link field and a group's sub-field")

  defp both_parents(parents) do
    error(
      List.last(parents),
      "a field cannot hang off more than one of a reference, a group and a flexible field"
    )
  end

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
