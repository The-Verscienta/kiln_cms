defmodule KilnCMS.CMS.Validations.FieldConditions do
  @moduledoc """
  Shape-checks a `FormField.conditions` map at write time so the submission
  pipeline and the public JS can trust it (see
  `KilnCMS.CMS.Validations.ConditionsShape` for the shared rules).
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Validations.ConditionsShape

  @impl true
  def validate(changeset, _opts, _context) do
    conditions = Ash.Changeset.get_attribute(changeset, :conditions) || %{}

    case ConditionsShape.check(conditions) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, InvalidAttribute.exception(field: :conditions, message: message)}
    end
  end
end
