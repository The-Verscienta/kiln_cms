defmodule KilnCMS.CMS.Validations.ItemBounds do
  @moduledoc """
  Ensures a list `FieldDefinition`'s `min_items` does not exceed its
  `max_items` — a bound no value could satisfy. Each bound on its own is
  range-checked by the attribute's constraints, and both are cleared on a
  field that is not `multiple` (`KilnCMS.CMS.Changes.ClearMultiple`).
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    min = Ash.Changeset.get_attribute(changeset, :min_items)
    max = Ash.Changeset.get_attribute(changeset, :max_items)

    if is_integer(min) and is_integer(max) and min > max do
      {:error,
       InvalidAttribute.exception(
         field: :min_items,
         message: "must not be more than the maximum (%{max})",
         vars: [max: max]
       )}
    else
      :ok
    end
  end
end
