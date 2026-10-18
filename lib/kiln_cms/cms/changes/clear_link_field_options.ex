defmodule KilnCMS.CMS.Changes.ClearLinkFieldOptions do
  @moduledoc """
  On a link field (`link_of_id` set, R3), resets the options that only mean
  something on a record-level field: `searchable` and `names_record` (search
  reads a record's own fields, not the data on its connections) and
  `localization` (a link value lives inside its reference field's value, so
  it follows that field across locales).

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  never renders those controls for a link field, so clearing beats an error
  on a control nobody can see. `multiple` needs nothing here — no link field
  type can hold a list, so `ClearMultiple` already clears it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:searchable, false)
      |> Ash.Changeset.force_change_attribute(:names_record, false)
      |> Ash.Changeset.force_change_attribute(:localization, :localized)
    end
  end
end
