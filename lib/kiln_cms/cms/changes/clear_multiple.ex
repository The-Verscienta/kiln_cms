defmodule KilnCMS.CMS.Changes.ClearMultiple do
  @moduledoc """
  Clears a `FieldDefinition`'s `multiple` flag whenever its type cannot hold a
  list — only a `:media` field (a gallery) or a `:reference` field (a list of
  references) can — and clears the `min_items` / `max_items` bounds whenever
  the field is not `multiple`.

  The same stance as `KilnCMS.CMS.Changes.ClearCompute`: the fields admin shows
  the single-or-list toggle only for those types, so switching an existing list
  field to another type submits no `multiple` param, and the stored `true`
  would otherwise survive on a type that can never honour it. Clearing rather
  than rejecting keeps the error off a control the form no longer renders.
  """
  use Ash.Resource.Change

  @list_types [:media, :reference]

  @doc "The field types that may set `multiple`."
  @spec list_types() :: [atom()]
  def list_types, do: @list_types

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      if Ash.Changeset.get_attribute(changeset, :field_type) in @list_types do
        changeset
      else
        Ash.Changeset.force_change_attribute(changeset, :multiple, false)
      end

    if Ash.Changeset.get_attribute(changeset, :multiple) do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:min_items, nil)
      |> Ash.Changeset.force_change_attribute(:max_items, nil)
    end
  end
end
