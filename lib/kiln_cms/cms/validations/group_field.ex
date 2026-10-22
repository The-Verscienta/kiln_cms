defmodule KilnCMS.CMS.Validations.GroupField do
  @moduledoc """
  The rules for a group sub-field (`FieldDefinition.group_of_id`), the twin of
  `KilnCMS.CMS.Validations.LinkField`:

    * its parent is a `:group` field of the same site — read under the
      changeset's tenant, so an id from another site does not resolve;
    * the parent is itself a field of a content type, not a sub-field or a
      link field: nesting stops at one level;
    * it is one of the plain types (`FieldDefinition.link_field_types/0`), so
      a group never holds a group, a media snapshot or a reference;
    * it stays with the group it was created under — moving a sub-field to
      another group would strand its values under the old one.

  Every other definition passes untouched.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :group_of_id) do
      nil -> unmoved(changeset)
      parent_id -> with :ok <- unmoved(changeset), do: validate_sub_field(changeset, parent_id)
    end
  end

  defp unmoved(%{action_type: :update} = changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :group_of_id),
      do: error(:group_of_id, "a sub-field stays in the group it was added to"),
      else: :ok
  end

  defp unmoved(_changeset), do: :ok

  defp validate_sub_field(changeset, parent_id) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    case parent(parent_id, changeset.to_tenant) do
      nil ->
        error(:group_of_id, "is not a field of this site")

      %{field_type: parent_type} when parent_type != :group ->
        error(:group_of_id, "sub-fields can only be added to a group field")

      %{} = group when not is_nil(group.group_of_id) or not is_nil(group.link_of_id) ->
        error(:group_of_id, "a sub-field cannot have sub-fields of its own")

      _group ->
        if type in FieldDefinition.link_field_types(),
          do: :ok,
          else: error(:field_type, "can't be used inside a group", type)
    end
  end

  # As the cms registry reader, under the write's tenant: this is the schema,
  # not content, and the writer is already an admin by the time it runs.
  defp parent(id, tenant) do
    case KilnCMS.CMS.get_field_definition(id,
           actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
           tenant: tenant
         ) do
      {:ok, definition} -> definition
      _error -> nil
    end
  end

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}
end
