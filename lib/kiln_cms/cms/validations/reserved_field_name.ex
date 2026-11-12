defmodule KilnCMS.CMS.Validations.ReservedFieldName do
  @moduledoc """
  A `KilnCMS.CMS.FormField` can't be named like the honeypot input
  (`KilnCMS.Forms.reserved_field_names/0`, #2267), whatever its type: a
  visitor who fills such a field trips the honeypot, and the submission is
  discarded as spam.

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
    if choosing_name?(changeset) and
         KilnCMS.Forms.reserved_field_name?(Ash.Changeset.get_attribute(changeset, :name)) do
      {:error,
       InvalidAttribute.exception(
         field: :name,
         message: gettext("is reserved for spam protection")
       )}
    else
      :ok
    end
  end

  defp choosing_name?(%{action_type: :create}), do: true

  defp choosing_name?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :name) or
      Ash.Changeset.changing_attribute?(changeset, :field_type)
  end
end
