defmodule KilnCMS.CMS.Validations.ReferenceTarget do
  @moduledoc """
  A `:reference` custom field must declare which content types it points at,
  and every one must exist in the merged registry (compiled or dynamic).

  It names them in exactly one of two ways:

    * `target_type` — one type name string, the documented option for a
      field that links to one type; or
    * `target_types` — a list of type names, for a field that links to
      several (a polymorphic reference, R2).

  Setting both, or neither, is refused, as is a list naming a type twice.
  Other field types ignore both.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :reference do
      target = Ash.Changeset.get_attribute(changeset, :target_type)
      targets = Ash.Changeset.get_attribute(changeset, :target_types) || []

      validate_targets(blank_to_nil(target), targets)
    else
      :ok
    end
  end

  defp validate_targets(nil, []),
    do: error(:target_type, "pick the type of content this field links to")

  defp validate_targets(target, []), do: known(:target_type, target)

  # A blank entry never gets here: the `{:array, :string}` attribute casts
  # `""` to nil and refuses nil items.
  defp validate_targets(nil, targets) do
    case targets -- Enum.uniq(targets) do
      [twice | _] -> error(:target_types, "lists #{twice} twice", twice)
      [] -> Enum.find_value(targets, :ok, &unknown(:target_types, &1))
    end
  end

  defp validate_targets(_target, _targets),
    do:
      error(
        :target_types,
        "set either one target type or a list of target types, not both"
      )

  defp known(field, name) do
    cond do
      not is_nil(ContentTypes.get(name)) -> :ok
      field == :target_type -> error(field, "is not a known content type", name)
      true -> error(field, "includes #{name}, which is not a known content type", name)
    end
  end

  # The error for a name that isn't a known type, or nil when it is.
  defp unknown(field, name) do
    case known(field, name) do
      :ok -> nil
      error -> error
    end
  end

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
