defmodule KilnCMS.CMS.Validations.KnownContentType do
  @moduledoc """
  Validates that a `:content_type` attribute names a real, registered KilnCMS
  content type (as discovered by `KilnCMS.CMS.ContentTypes`). Guards
  `FieldDefinition` rows from pointing at a type that doesn't exist.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :content_type) do
      nil ->
        :ok

      type ->
        if ContentTypes.type?(type) do
          :ok
        else
          {:error,
           InvalidAttribute.exception(
             field: :content_type,
             message: "is not a known content type",
             value: type
           )}
        end
    end
  end
end
