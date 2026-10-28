defmodule KilnCMS.CMS.Changes.ClearDeliverPortable do
  @moduledoc """
  Clears a `FieldDefinition`'s `deliver_portable` flag whenever the field is
  not a top-level **rich** `:text` field.

  The same stance as `KilnCMS.CMS.Changes.ClearDeliverPlain`: the fields
  admin shows the toggle only for a rich `:text` field, so retyping one, or
  switching it to `format: :plain`, submits no `deliver_portable` param, and
  a stored `true` would otherwise linger on a field delivery never converts.
  A plain field is text as typed, which `custom_fields` already delivers as
  it is. A link field (R3) and a group sub-field are cleared too: their
  values live inside another field's, and `custom_fields_portable` only
  projects a record's own fields.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :text and
         Ash.Changeset.get_attribute(changeset, :format) == :rich and
         is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) and
         is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id)) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :deliver_portable, false)
    end
  end
end
