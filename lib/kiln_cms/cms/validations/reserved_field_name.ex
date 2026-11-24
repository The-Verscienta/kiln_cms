defmodule KilnCMS.CMS.Validations.ReservedFieldName do
  @moduledoc """
  A `KilnCMS.CMS.FormField` can't take a reserved name
  (`KilnCMS.Forms.reserved_field_names/0`), whatever its type:

    * the honeypot input's (#2267): a visitor who fills such a field trips
      the honeypot, and the submission is discarded as spam;
    * `locale` (#2716): the submission's language is recorded from the param
      of that name, so a visitor's answer would be recorded as it too.

  The refusal says which, per name (`KilnCMS.Forms.reserved_field_reason/1`).

  The rule guards choosing the name, so it runs on create and on an update
  that changes `name` or `field_type`. #2261 already refused a retype of such
  a row, and the owner's decision on #2267 refuses new and edited fields. Any
  other update of a field that already carries the name (label, position,
  required, options, …) still saves: the form keeps working, the builder
  flags the field, and its reorder writes one `position` update per field,
  which must not half-apply. Ash drops an update value equal to the stored
  one, so the builder's whole-panel save with the name unchanged is not a
  change of `name`.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    reason =
      choosing_name?(changeset) &&
        KilnCMS.Forms.reserved_field_reason(Ash.Changeset.get_attribute(changeset, :name))

    if reason do
      {:error, InvalidAttribute.exception(field: :name, message: message(reason))}
    else
      :ok
    end
  end

  defp message(:honeypot), do: gettext("is reserved for spam protection")
  defp message(:locale), do: gettext("is reserved for the submission's language")

  defp choosing_name?(%{action_type: :create}), do: true

  defp choosing_name?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :name) or
      Ash.Changeset.changing_attribute?(changeset, :field_type)
  end
end
