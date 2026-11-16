defmodule KilnCMS.CMS.Validations.NumberOptions do
  @moduledoc """
  A number field's `step` (#2432) must make sense for its type and bounds:

    * a whole step on an `:integer` field (the editor's input would otherwise
      offer values the field can't store);
    * no larger than the span between `validation.min` and `validation.max`
      when both are set, since a slider or spinner with a step wider than its
      range could only ever sit at one end.

  `step > 0` is the attribute's own constraint; `prefix` and `suffix` are
  plain text and need no check. `KilnCMS.CMS.Changes.ClearNumberOptions` has
  already dropped the options from a field that is not a number.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldConstraints

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :step) do
      step when is_number(step) -> check(changeset, step)
      _none -> :ok
    end
  end

  defp check(changeset, step) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)
    validation = FieldConstraints.normalize(Ash.Changeset.get_attribute(changeset, :validation))

    cond do
      type == :integer and trunc(step) != step ->
        error(gettext("must be a whole number on an integer field"))

      wider_than_range?(step, validation) ->
        error(gettext("can't be more than the span between min and max"))

      true ->
        :ok
    end
  end

  defp wider_than_range?(step, %{"min" => min, "max" => max})
       when is_number(min) and is_number(max),
       do: step > max - min

  defp wider_than_range?(_step, _validation), do: false

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :step, message: message)}
end
