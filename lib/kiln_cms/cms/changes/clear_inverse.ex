defmodule KilnCMS.CMS.Changes.ClearInverse do
  @moduledoc """
  Keeps a `FieldDefinition`'s reverse-field options (`inverse_label`,
  `inverse_name`, R4 in `docs/relationships-plan.md`) where they mean
  something.

    * Only a top-level `:reference` field has another side, so on any other
      type, and on a link field (R3), both are cleared — the same stance as
      `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin shows the input
      only for a reference, and clearing beats an error on a control nobody
      can see.
    * A label with no machine name suggests one, as a field's own label does
      (`KilnCMS.CMS.FieldDefinition.name_from_label/1`), so an admin who only
      types "Recipes using this ingredient" gets `recipes_using_this_ingredient`.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def change(changeset, _opts, _context) do
    reference? =
      Ash.Changeset.get_attribute(changeset, :field_type) == :reference and
        is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id))

    label = Ash.Changeset.get_attribute(changeset, :inverse_label)
    name = Ash.Changeset.get_attribute(changeset, :inverse_name)

    cond do
      not reference? ->
        changeset
        |> Ash.Changeset.force_change_attribute(:inverse_label, nil)
        |> Ash.Changeset.force_change_attribute(:inverse_name, nil)

      is_binary(label) and blank?(name) ->
        case FieldDefinition.name_from_label(label) do
          "" -> changeset
          suggested -> Ash.Changeset.force_change_attribute(changeset, :inverse_name, suggested)
        end

      true ->
        changeset
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
