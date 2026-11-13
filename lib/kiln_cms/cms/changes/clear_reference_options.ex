defmodule KilnCMS.CMS.Changes.ClearReferenceOptions do
  @moduledoc """
  Resets a `FieldDefinition`'s target-side options — `max_sources` (R1b),
  `on_target_delete` (R5), `schema_org_property` (#2044) and `selection`
  (#2285) — whenever the field is not a `:reference`. On a reference it
  normalizes `selection` to string keys (an empty one is nil).

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  shows those controls only for a reference, so retyping one to another type
  submits neither, and a stored cap or delete rule would otherwise linger on a
  field that has no targets to apply it to. A link field (R3) is never a
  reference, so it is cleared too.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ReferenceSelection

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :reference do
      normalize_selection(changeset)
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:max_sources, nil)
      |> Ash.Changeset.force_change_attribute(:on_target_delete, :keep)
      |> Ash.Changeset.force_change_attribute(:schema_org_property, nil)
      |> Ash.Changeset.force_change_attribute(:selection, nil)
    end
  end

  defp normalize_selection(changeset) do
    case Ash.Changeset.fetch_change(changeset, :selection) do
      {:ok, selection} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :selection,
          ReferenceSelection.normalize(selection)
        )

      :error ->
        changeset
    end
  end
end
