defmodule KilnCMS.CMS.Validations.FlexibleRetype do
  @moduledoc """
  Refuses an update that changes a field's `field_type` **to or from**
  `:flexible` (#2282, ADR 0065).

  A flexible field's stored value is a list of `_type`-tagged items and its
  definition owns item types (`flex_of_id` rows). Retyping a plain field to
  `:flexible` would leave its values in the old shape, which a write that names
  the field then refuses as "must be a list of items"; retyping a flexible
  field away would leave its item types attached to a field that is no longer
  flexible, and its items under a key nothing declares. Neither is a rename of
  the same data, so the way to change one into the other is to define the new
  field and delete the old one.

  It lives on the resource, not in the fields screen, so the admin form, a
  field-sync import (`KilnCMS.CMS.FieldSync`) and a direct call of the code
  interface are refused alike.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(%{action_type: :update} = changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :field_type) do
      from = changeset.data.field_type
      to = Ash.Changeset.get_attribute(changeset, :field_type)

      if :flexible in [from, to],
        do:
          {:error,
           InvalidAttribute.exception(
             field: :field_type,
             message:
               "a field can't be changed to or from a flexible field: " <>
                 "add a new field and delete this one",
             value: to
           )},
        else: :ok
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context), do: :ok
end
