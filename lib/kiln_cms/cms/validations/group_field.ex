defmodule KilnCMS.CMS.Validations.GroupField do
  @moduledoc """
  The rules for a group sub-field (`FieldDefinition.group_of_id`), the twin of
  `KilnCMS.CMS.Validations.LinkField`:

    * its parent is a `:group` field of the same site — read under the
      changeset's tenant, so an id from another site does not resolve;
    * the parent is itself a field of a content type, not a sub-field or a
      link field: nesting stops at one level — except that the parent may be
      an **item type** of a flexible field (`flex_of_id`, #2282), the one
      group that is not a field of a type;
    * it is one of the plain types (`FieldDefinition.link_field_types/0`), so
      a group never holds a group, a media snapshot or a reference; under an
      item type it may also be a `:flexible` field
      (`FieldDefinition.item_field_types/0`), so an item can hold a list of its
      own, as deep as `FieldDefinition.max_flexible_depth/0` allows;
    * it is a *setting* (`item_setting`) only under an item type, and then a
      plain type — never a nested flexible field;
    * it stays with the group it was created under — moving a sub-field to
      another group would strand its values under the old one.

  Every other definition passes untouched.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.Validations.FlexibleField

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :group_of_id) do
      nil ->
        with :ok <- unmoved(changeset), do: not_a_setting(changeset)

      parent_id ->
        with :ok <- unmoved(changeset), do: validate_sub_field(changeset, parent_id)
    end
  end

  defp unmoved(%{action_type: :update} = changeset) do
    cond do
      Ash.Changeset.changing_attribute?(changeset, :group_of_id) ->
        error(:group_of_id, "a sub-field stays in the group it was added to")

      # Flipping it would strand stored values between content and `_settings`.
      Ash.Changeset.changing_attribute?(changeset, :item_setting) ->
        error(:item_setting, "can't change once the sub-field exists")

      true ->
        :ok
    end
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

      group ->
        item_type? = FieldDefinition.item_type?(group)

        with :ok <- sub_field_type(type, item_type?, group, changeset.to_tenant) do
          setting(changeset, type, item_type?)
        end
    end
  end

  defp sub_field_type(type, true, group, tenant) do
    cond do
      type not in FieldDefinition.item_field_types() ->
        error(:field_type, "can't be used inside an item type", type)

      type == :flexible ->
        nested_depth(group, tenant)

      true ->
        :ok
    end
  end

  defp sub_field_type(type, false, _group, _tenant) do
    cond do
      type == :flexible ->
        error(:field_type, "a flexible field can only be added to an item type", type)

      type in FieldDefinition.link_field_types() ->
        :ok

      true ->
        error(:field_type, "can't be used inside a group", type)
    end
  end

  # A flexible field inside an item type sits one level below the flexible
  # field that owns the item type.
  defp nested_depth(item_type, tenant) do
    owner = FlexibleField.parent(item_type.flex_of_id, tenant)

    if is_nil(owner) or
         FlexibleField.depth(owner, tenant) + 1 <= FieldDefinition.max_flexible_depth(),
       do: :ok,
       else:
         error(
           :field_type,
           "flexible fields nest at most #{FieldDefinition.max_flexible_depth()} levels deep"
         )
  end

  # Settings are the item type's own, and plain.
  defp setting(changeset, type, item_type?) do
    cond do
      Ash.Changeset.get_attribute(changeset, :item_setting) != true -> :ok
      not item_type? -> error(:item_setting, "only a sub-field of an item type can be a setting")
      type == :flexible -> error(:item_setting, "a setting can't be a flexible field")
      true -> :ok
    end
  end

  defp not_a_setting(changeset) do
    if Ash.Changeset.get_attribute(changeset, :item_setting) == true,
      do: error(:item_setting, "only a sub-field of an item type can be a setting"),
      else: :ok
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
