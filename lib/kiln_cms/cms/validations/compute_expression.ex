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

    # Only `:computed` is validated. There is deliberately no "a non-computed
    # field must not carry a formula" branch: the admin form renders the formula
    # input only for `:computed`, so switching an existing computed field to any
    # other type submits no `compute` param, `get_attribute/2` falls back to the
    # stored value, and the error would land on a field with no rendered input —
    # an unrecoverable dead end. `ClearCompute` nils the column instead, which is
    # the same stance `ReferenceTarget` takes toward a stale `target_type`.
    cond do
      field_type != :computed -> :ok
      blank?(compute) -> error("a computed field needs a formula, e.g. {{ reading_time(body) }}")
      Ash.Changeset.get_attribute(changeset, :required) -> error_required()
      true -> validate_formula(compute)
    end
  end

  defp validate_formula(compute) do
    case Computed.parse(compute) do
      {:ok, _template} -> :ok
      {:error, message} -> error("the formula #{message}")
    end
  end

  # A computed field has no editor to require anything of — its input is
  # read-only. Allowing `required` would let a formula that evaluates blank for
  # some record attach an uncorrectable error to every create and every update
  # of the whole content type.
  defp error_required do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :required,
       message: "a computed field can't be required — its value isn't the editor's to supply"
     )}
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :compute, message: message)}
end
