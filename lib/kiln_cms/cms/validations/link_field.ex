defmodule KilnCMS.CMS.Validations.LinkField do
  @moduledoc """
  The rules for a link field (`FieldDefinition.link_of_id`, R3 in
  `docs/relationships-plan.md`):

    * its parent is a `:reference` field of the same site — read under the
      changeset's tenant, so an id from another site does not resolve;
    * the parent is itself a field of a content type, not a link field:
      nesting stops at one level;
    * it is one of the plain types (`FieldDefinition.link_field_types/0`);
    * it stays with the parent it was created under — moving a link field to
      another reference would strand its values under the old one.

  Every other definition passes untouched.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :link_of_id) do
      nil -> unmoved(changeset)
      parent_id -> with :ok <- unmoved(changeset), do: validate_link(changeset, parent_id)
    end
  end

  defp unmoved(%{action_type: :update} = changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :link_of_id),
      do: error(:link_of_id, "a link field stays on the reference field it was added to"),
      else: :ok
  end

  defp unmoved(_changeset), do: :ok

  defp validate_link(changeset, parent_id) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    case parent(parent_id, changeset.to_tenant) do
      nil ->
        error(:link_of_id, "is not a field of this site")

      %{field_type: parent_type} when parent_type != :reference ->
        error(:link_of_id, "link fields can only be added to a reference field")

      %{link_of_id: grandparent} when not is_nil(grandparent) ->
        error(:link_of_id, "a link field cannot have link fields of its own")

      _reference ->
        if type in FieldDefinition.link_field_types(),
          do: :ok,
          else: error(:field_type, "can't be used for details on a connection", type)
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
