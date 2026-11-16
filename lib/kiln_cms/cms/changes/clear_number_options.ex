defmodule KilnCMS.CMS.Changes.ClearNumberOptions do
  @moduledoc """
  Clears a `FieldDefinition`'s number options (#2432) — `step`, `prefix` and
  `suffix` — whenever the field is not an `:integer` or `:float`.

  The same stance as `KilnCMS.CMS.Changes.ClearDeliverPlain`: the fields admin
  shows the inputs only for a number, so retyping one submits nothing for
  them, and a stored `step` would otherwise linger on a field whose editor
  input never reads it. A `multiple` number keeps them (each item is a number
  input), and so does a group sub-field or link field of number type, whose
  inline input honors the step and adornments too.

  Runs on create and update, so a write that retypes a number and posts a step
  in the same request ends with none.
  """
  use Ash.Resource.Change

  @number_types [:integer, :float]

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) in @number_types do
      changeset
    else
      Enum.reduce([:step, :prefix, :suffix], changeset, &clear/2)
    end
  end

  defp clear(attribute, changeset) do
    if is_nil(Ash.Changeset.get_attribute(changeset, attribute)),
      do: changeset,
      else: Ash.Changeset.force_change_attribute(changeset, attribute, nil)
  end
end
