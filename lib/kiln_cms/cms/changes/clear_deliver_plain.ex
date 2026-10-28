defmodule KilnCMS.CMS.Changes.ClearDeliverPlain do
  @moduledoc """
  Clears a `FieldDefinition`'s `deliver_plain` flag whenever the field is not
  a top-level `:text` field.

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  shows the toggle only for a `:text` field, so retyping one submits no
  `deliver_plain` param, and a stored `true` would otherwise linger on a field
  delivery never strips. A link field (R3) is cleared too: its value lives
  inside its reference field's snapshot, and `custom_fields_plain` only
  projects a record's own fields. A group sub-field likewise: its value is
  one key of its group's rows.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :text and
         is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) and
         is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id)) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :deliver_plain, false)
    end
    |> clear_breaks()
  end

  # `plain_breaks` shapes the plain rendition, so it means nothing without
  # one — and the fields admin shows it only beside a ticked `deliver_plain`.
  defp clear_breaks(changeset) do
    if Ash.Changeset.get_attribute(changeset, :deliver_plain) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :plain_breaks, false)
    end
  end
end
