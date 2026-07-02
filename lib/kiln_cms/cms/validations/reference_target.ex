defmodule KilnCMS.CMS.Validations.ReferenceTarget do
  @moduledoc """
  A `:reference` custom field must declare which content type it points at
  (`target_type` — a type name string, compiled or dynamic), and that type must
  exist in the merged registry. Other field types ignore `target_type`.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :reference do
      target = Ash.Changeset.get_attribute(changeset, :target_type)

      cond do
        target in [nil, ""] ->
          {:error,
           InvalidAttribute.exception(
             field: :target_type,
             message: "a reference field must declare a target content type"
           )}

        is_nil(ContentTypes.get(target)) ->
          {:error,
           InvalidAttribute.exception(
             field: :target_type,
             message: "is not a known content type",
             value: target
           )}

        true ->
          :ok
      end
    else
      :ok
    end
  end
end
