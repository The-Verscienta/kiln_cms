defmodule KilnCMS.CMS.Validations.InverseName do
  @moduledoc """
  The rules for a reference's other side (`inverse_label` / `inverse_name`,
  R4 in `docs/relationships-plan.md`):

    * the machine name is a safe identifier, the shape a field's own `name`
      takes, since GraphQL (`referencedBy(inverse:)`) and the schema export
      name the reverse field by it;
    * a machine name comes with a label — the label is what the target's
      editor shows, so a name alone would show an editor a machine key;
    * it is unique among the reverse fields of every type the reference may
      point at, so `inverse: "recipes"` on an Ingredient names one field of one
      source type.

  Definitions without a reverse side pass untouched (`Changes.ClearInverse`
  clears the options anywhere they mean nothing).
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    label = Ash.Changeset.get_attribute(changeset, :inverse_label)
    name = effective_name(Ash.Changeset.get_attribute(changeset, :inverse_name), label)

    cond do
      is_nil(name) ->
        :ok

      Ash.Changeset.get_attribute(changeset, :field_type) != :reference ->
        :ok

      not Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name) ->
        error(
          :inverse_name,
          "must be lowercase letters, digits and underscores, starting with a letter",
          name
        )

      label in [nil, ""] ->
        error(:inverse_label, "say what the other side calls this connection")

      clash = clash(changeset, name) ->
        error(
          :inverse_name,
          "is already used by the #{clash.label} field for the same content type",
          name
        )

      true ->
        :ok
    end
  end

  # `Changes.ClearInverse` fills the name in from the label; the validation
  # may run before it, so it reads the same suggestion.
  defp effective_name(name, _label) when is_binary(name) and name != "", do: name

  defp effective_name(_name, label) when is_binary(label) do
    case FieldDefinition.name_from_label(label) do
      "" -> nil
      name -> name
    end
  end

  defp effective_name(_name, _label), do: nil

  # Another reference field of this site with the same other-side name that
  # may point at one of the same types. As the cms registry reader, under the
  # write's tenant: this is the schema, and the writer is an admin already.
  defp clash(changeset, name) do
    targets =
      FieldDefinition.reference_targets(%{
        target_type: Ash.Changeset.get_attribute(changeset, :target_type),
        target_types: Ash.Changeset.get_attribute(changeset, :target_types) || []
      })

    own_id = changeset.data && changeset.data.id

    Enum.find_value(targets, fn target ->
      target
      |> KilnCMS.CMS.reverse_field_definitions_for!(
        actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
        authorize_with: :error,
        tenant: changeset.to_tenant
      )
      |> Enum.find(&(&1.inverse_name == name and &1.id != own_id))
    end)
  end

  defp error(field, message, value \\ nil),
    do: {:error, InvalidAttribute.exception(field: field, message: message, value: value)}
end
