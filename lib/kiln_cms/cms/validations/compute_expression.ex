defmodule KilnCMS.CMS.Validations.ComputeExpression do
  @moduledoc """
  Ensures a `FieldDefinition` of type `:computed` carries a `compute` template
  that actually parses (#429), and that no other type carries one.

  Parsing at *definition* time is the point: an admin gets
  `calls unknown function slugfy/1` while defining the field, rather than every
  record silently computing blank. Only syntax, function names and arities are
  checked here — references resolve at write time, since the fields a formula
  mentions may be defined after it.

  The one reference check is for a **cycle**: a computed field may read
  another computed field (`KilnCMS.CMS.Computed.derive/3` evaluates them in
  dependency order), but not itself, directly or through others. The formula
  is checked against the type's other computed fields as stored, so defining
  the field that would close a loop is refused too, naming the loop.
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
      true -> validate_formula(changeset, compute)
    end
  end

  defp validate_formula(changeset, compute) do
    case Computed.parse(compute) do
      {:ok, template} -> validate_acyclic(changeset, template)
      {:error, message} -> error("the formula #{message}")
    end
  end

  # Only a formula that reads some custom field can close a loop, so one over
  # the document alone (`{{ reading_time(body) }}`) skips the read.
  defp validate_acyclic(changeset, template) do
    name = Ash.Changeset.get_attribute(changeset, :name)

    if is_binary(name) and Computed.references(template) != [] do
      own = %{name: name, compute: template}

      case Computed.cycle([own | siblings(changeset)], name) do
        nil ->
          :ok

        loop ->
          error(
            "the formula makes a loop: #{Enum.join(loop, " → ")} — a computed field " <>
              "can't depend on its own value"
          )
      end
    else
      :ok
    end
  end

  # The type's other computed fields, as stored. Read as the system actor and
  # fail closed, like the write path's own definitions read: a refused read
  # must not pass a loop off as "no siblings".
  defp siblings(changeset) do
    opts = [
      actor: KilnCMS.CMS.Bookkeeping.system(),
      authorize_with: :error,
      tenant: changeset.to_tenant
    ]

    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    definition_id = Ash.Changeset.get_attribute(changeset, :type_definition_id)

    definitions =
      cond do
        definition_id -> KilnCMS.CMS.field_definitions_for_definition!(definition_id, opts)
        content_type -> KilnCMS.CMS.field_definitions_for!(content_type, opts)
        true -> []
      end

    Enum.filter(definitions, &(&1.field_type == :computed and &1.id != changeset.data.id))
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
