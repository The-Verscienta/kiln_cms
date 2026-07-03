defmodule KilnCMS.CMS.Validations.KnownFieldType do
  @moduledoc """
  A `FieldDefinition`'s `field_type` must be registered: one of the built-in
  value types or a plugin-contributed `Kiln.FieldType`
  (`KilnCMS.CMS.FieldTypes.names/0`). Replaces a compile-baked `one_of`
  constraint so the allowed set follows the installed plugins.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    if is_nil(type) or type in KilnCMS.CMS.FieldTypes.names() do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :field_type,
         message: "is not a registered field type",
         value: type
       )}
    end
  end
end
