defmodule KilnCMS.CMS.Validations.ReferenceEditInline do
  @moduledoc """
  Keeps a reference field's `edit_inline` flag (#2283) where the editor can
  honor it: a **top-level** `:reference`.

  A reference that is a sub-field of a group, a link field or an item type of
  a flexible field is refused, not silently cleared: the cards are addressed by
  the picker's row key on the record's own form, and those nested pickers are
  addressed by path (#2282). On any type but `:reference` the flag is cleared
  by `KilnCMS.CMS.Changes.ClearReferenceOptions` instead, so retyping a field
  never fails on a control the form no longer shows.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :edit_inline) == true and
         Ash.Changeset.get_attribute(changeset, :field_type) == :reference and
         not FieldDefinition.top_level?(changeset) do
      {:error,
       InvalidAttribute.exception(
         field: :edit_inline,
         message: gettext("is only for a reference field of the record itself"),
         value: true
       )}
    else
      :ok
    end
  end
end
