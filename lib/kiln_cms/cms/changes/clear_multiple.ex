defmodule KilnCMS.CMS.Changes.ClearMultiple do
  @moduledoc """
  Clears a `FieldDefinition`'s `multiple` flag whenever its type is not
  `:media` — only a media field can hold a gallery.

  The same stance as `KilnCMS.CMS.Changes.ClearCompute`: the fields admin shows
  the gallery toggle only for `:media`, so switching an existing gallery field
  to another type submits no `multiple` param, and the stored `true` would
  otherwise survive on a type that can never honour it. Clearing rather than
  rejecting keeps the error off a control the form no longer renders.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :media do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :multiple, false)
    end
  end
end
