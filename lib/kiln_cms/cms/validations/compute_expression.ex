defmodule KilnCMS.CMS.Validations.ComputeExpression do
  @moduledoc """
  Ensures a `FieldDefinition` of type `:computed` carries a `compute` template
  that actually parses (#429), and that no other type carries one.

  Parsing at *definition* time is the point: an admin gets
  `calls unknown function slugfy/1` while defining the field, rather than every
  record silently computing blank. Only syntax, function names and arities are
  checked here — references resolve at write time, since the fields a formula
  mentions may be defined after it.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Computed

  @impl true
  def validate(changeset, _opts, _context) do
    field_type = Ash.Changeset.get_attribute(changeset, :field_type)
    compute = Ash.Changeset.get_attribute(changeset, :compute)

    case {field_type, blank?(compute)} do
      {:computed, true} ->
        error("a computed field needs a formula, e.g. {{ reading_time(body) }}")

      {:computed, false} ->
        case Computed.parse(compute) do
          {:ok, _template} -> :ok
          {:error, message} -> error("the formula #{message}")
        end

      {_other, false} ->
        error("only a computed field can carry a formula")

      {_other, true} ->
        :ok
    end
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :compute, message: message)}
end
