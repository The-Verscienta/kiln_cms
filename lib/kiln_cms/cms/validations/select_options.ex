defmodule KilnCMS.CMS.Validations.SelectOptions do
  @moduledoc """
  Ensures a `FieldDefinition` of type `:select` lists at least one option (an
  empty `options` list is "present" but meaningless for a select) — unless it
  takes terms of its own (`allow_custom`), where `options` only seeds the
  picker's suggestions.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    field_type = Ash.Changeset.get_attribute(changeset, :field_type)
    options = Ash.Changeset.get_attribute(changeset, :options) || []

    # Both flags, not `allow_custom` alone: `ClearMultiple` drops it from a
    # single select, and this must not depend on which of the two runs first.
    allow_custom? =
      Ash.Changeset.get_attribute(changeset, :allow_custom) == true and
        Ash.Changeset.get_attribute(changeset, :multiple) == true

    if field_type == :select and options == [] and not allow_custom? do
      {:error,
       InvalidAttribute.exception(
         field: :options,
         message: "a select field must list at least one option"
       )}
    else
      :ok
    end
  end
end
