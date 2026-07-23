defmodule KilnCMS.CMS.Validations.SelectOptions do
  @moduledoc """
  Ensures a choice-type field (`:select`, or a `FormField`'s `:radio` /
  `:checkboxes`) lists at least one option (an empty `options` list is
  "present" but meaningless for a choice). Shared by `FieldDefinition` and
  `FormField`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @choice_types [:select, :radio, :checkboxes]

  @impl true
  def validate(changeset, _opts, _context) do
    field_type = Ash.Changeset.get_attribute(changeset, :field_type)
    options = Ash.Changeset.get_attribute(changeset, :options) || []

    if field_type in @choice_types and options == [] do
      {:error,
       InvalidAttribute.exception(
         field: :options,
         message: "a choice field must list at least one option"
       )}
    else
      :ok
    end
  end
end
