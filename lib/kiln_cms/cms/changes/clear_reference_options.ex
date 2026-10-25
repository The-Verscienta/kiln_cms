defmodule KilnCMS.CMS.Changes.ClearReferenceOptions do
  @moduledoc """
  Resets a `FieldDefinition`'s target-side options — `max_sources` (R1b),
  `on_target_delete` (R5) and `schema_org_property` (#2044) — whenever the
  field is not a `:reference`.

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  shows those controls only for a reference, so retyping one to another type
  submits neither, and a stored cap or delete rule would otherwise linger on a
  field that has no targets to apply it to. A link field (R3) is never a
  reference, so it is cleared too.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :reference do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:max_sources, nil)
      |> Ash.Changeset.force_change_attribute(:on_target_delete, :keep)
      |> Ash.Changeset.force_change_attribute(:schema_org_property, nil)
    end
  end
end
