defmodule KilnCMS.CMS.Changes.ClearMultiple do
  @moduledoc """
  Clears a `FieldDefinition`'s `multiple` flag whenever its type cannot hold a
  list — only a `:media` field (a gallery), a `:reference` field (a list of
  references), a `:group` (repeating rows), a `:select` (several terms) or a
  `:string` (a list of phrases) can —
  and clears the `min_items` / `max_items` bounds whenever the field is not
  `multiple`.

  A multiple `:select` or `:string` is a record-level field only: a link
  field (R3) and a group sub-field hold one scalar each (`JoinGraduation` maps a link field to
  one column, a group row to one value per key), so `multiple` is cleared on
  one. `allow_custom` (the open vocabulary) is cleared on anything that is not
  a multiple select.

  The same stance as `KilnCMS.CMS.Changes.ClearCompute`: the fields admin shows
  the single-or-list toggle only for those types, so switching an existing list
  field to another type submits no `multiple` param, and the stored `true`
  would otherwise survive on a type that can never honour it. Clearing rather
  than rejecting keeps the error off a control the form no longer renders.
  """
  use Ash.Resource.Change

  @list_types [:media, :reference, :group, :select, :string]

  # The list types a link field or group sub-field may also be, as scalars.
  @scalar_list_types [:select, :string]

  @doc "The field types that may set `multiple`."
  @spec list_types() :: [atom()]
  def list_types, do: @list_types

  @impl true
  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    changeset =
      if type in @list_types and not (type in @scalar_list_types and sub_field?(changeset)) do
        changeset
      else
        Ash.Changeset.force_change_attribute(changeset, :multiple, false)
      end

    multiple? = Ash.Changeset.get_attribute(changeset, :multiple)

    changeset =
      if type == :select and multiple?,
        do: changeset,
        else: Ash.Changeset.force_change_attribute(changeset, :allow_custom, false)

    if multiple? do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:min_items, nil)
      |> Ash.Changeset.force_change_attribute(:max_items, nil)
    end
  end

  defp sub_field?(changeset) do
    not is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) or
      not is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id))
  end
end
