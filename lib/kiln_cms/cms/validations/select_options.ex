defmodule KilnCMS.CMS.Validations.SelectOptions do
  @moduledoc """
  Ensures a `FieldDefinition` of type `:select` lists at least one option (an
  empty `options` list is "present" but meaningless for a select).
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    field_type = Ash.Changeset.get_attribute(changeset, :field_type)
    options = Ash.Changeset.get_attribute(changeset, :options) || []

    if field_type == :select and options == [] do
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
