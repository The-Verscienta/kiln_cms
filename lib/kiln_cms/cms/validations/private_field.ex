defmodule KilnCMS.CMS.Validations.PrivateField do
  @moduledoc """
  Keeps a **private** `FieldDefinition` (#2044) to what Kiln can keep private.

  A private field's value reaches the site's editors and admins and no one
  else: it is left out of every fired artifact and every read by anyone
  below editor (`KilnCMS.CMS.PrivateFields`). That promise only holds for a
  value that stays where it is put, so a private field must be:

    * a **top-level** field of a plain type — `KilnCMS.CMS.PrivateFields.types/0`
      (the scalar types and `:user`). A reference, media item, group or
      computed value is copied into edges, usage tracking, structured data or
      other fields, and a link field or sub-field lives inside a value that is
      delivered whole;
    * **not searchable, not a name of the record, not delivered as plain text
      or Portable Text** — each of those copies the value into something
      public (`search_text`, the alias leg, `custom_fields_plain`,
      `custom_fields_portable`);
    * **not `:fallback`-localized** — a variant that inherits the value serves
      it through the `inherited_fields` calculation, which is no read of the
      field. `:shared` is fine: the copy stays under the same private
      definition.

  These are refused rather than cleared, unlike the other options the fields
  admin hides for a type: clearing `private` would silently publish a value
  an admin asked to keep back. A `:user` field is always private
  (`Changes.PrivateUserField`), so the rules apply to it too.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.PrivateFields

  @copies [
    searchable: "can't be searchable: search results would show it",
    names_record: "can't be a name of the record: search would match it",
    deliver_plain: "can't be delivered as plain text",
    deliver_portable: "can't be delivered as Portable Text"
  ]

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :private) == true do
      with :ok <- check_type(changeset), do: check_copies(changeset)
    else
      :ok
    end
  end

  defp check_type(changeset) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    nested? =
      not is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) or
        not is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id))

    cond do
      nested? ->
        error(:private, "is only for a top-level field, not one inside a relationship or group")

      type not in PrivateFields.types() ->
        error(:private, "is not available for a #{type} field")

      true ->
        :ok
    end
  end

  defp check_copies(changeset) do
    copied =
      Enum.find_value(@copies, :ok, fn {attribute, message} ->
        if Ash.Changeset.get_attribute(changeset, attribute) == true,
          do: error(attribute, "a private field " <> message)
      end)

    if copied == :ok and Ash.Changeset.get_attribute(changeset, :localization) == :fallback,
      do: error(:localization, "a private field can't inherit from another locale"),
      else: copied
  end

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}
end
