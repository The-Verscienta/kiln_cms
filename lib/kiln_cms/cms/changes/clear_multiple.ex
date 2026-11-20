defmodule KilnCMS.CMS.Changes.ClearMultiple do
  @moduledoc """
  Clears a `FieldDefinition`'s `multiple` flag whenever its type cannot hold a
  list — only a `:media` field (a gallery), a `:reference` field (a list of
  references), a `:group` (repeating rows) or a scalar list type
  (`KilnCMS.CMS.ScalarLists.types/0`: a `:select`'s terms, a `:string`'s
  phrases, and lists of numbers, dates, times, links, email addresses, phone
  numbers, colors, slugs and every plugin type that opts in) can —
  and clears the `min_items` / `max_items` bounds whenever the field is not
  `multiple`.

  A multiple scalar list is a record-level field only: a link
  field (R3) and a group sub-field hold one scalar each (`JoinGraduation` maps a link field to
  one column, a group row to one value per key), so `multiple` is cleared on
  one. `allow_custom` (the open vocabulary) is cleared on anything that is not
  a multiple select.

  A **held list** (`KilnCMS.CMS.FieldDefinition.held_list?/1`, #2680) is the
  exception: a list field whose type stopped taking lists (a plugin type whose
  `multiple?/0` no longer answers `true`). Clearing its flag would narrow every
  stored list on a reorder, a rename elsewhere or a field sync, so an update
  keeps `multiple` on it — unless the update passes `narrow_held_list?: true`,
  which only the fields admin's save does, after warning that each record
  keeps its first item.

  The same stance as `KilnCMS.CMS.Changes.ClearCompute`: the fields admin shows
  the single-or-list toggle only for those types, so switching an existing list
  field to another type submits no `multiple` param, and the stored `true`
  would otherwise survive on a type that can never honour it. Clearing rather
  than rejecting keeps the error off a control the form no longer renders.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ScalarLists

  @list_types [:media, :reference, :group, :flexible] ++ ScalarLists.types()

  # The list types a link field or group sub-field may also be, as scalars.
  @scalar_list_types ScalarLists.types()

  @doc "The field types that may set `multiple`."
  @spec list_types() :: [atom()]
  def list_types, do: @list_types

  @impl true
  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    changeset = clear_or_force(changeset, type)

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

  defp clear_or_force(changeset, type) do
    cond do
      type == :flexible or item_type?(changeset) ->
        Ash.Changeset.force_change_attribute(changeset, :multiple, true)

      list_capable?(changeset, type) ->
        changeset

      keep_held?(changeset) ->
        Ash.Changeset.force_change_attribute(changeset, :multiple, true)

      true ->
        Ash.Changeset.force_change_attribute(changeset, :multiple, false)
    end
  end

  defp list_capable?(changeset, type),
    do: type in @list_types and not (type in @scalar_list_types and sub_field?(changeset))

  # A held list stays one until an admin narrows it on purpose.
  defp keep_held?(%{action_type: :update, data: data} = changeset),
    do:
      KilnCMS.CMS.FieldDefinition.held_list?(data) and
        Ash.Changeset.get_argument(changeset, :narrow_held_list?) != true

  defp keep_held?(_changeset), do: false

  defp item_type?(changeset),
    do: not is_nil(Ash.Changeset.get_attribute(changeset, :flex_of_id))

  defp sub_field?(changeset), do: not KilnCMS.CMS.FieldDefinition.top_level?(changeset)
end
