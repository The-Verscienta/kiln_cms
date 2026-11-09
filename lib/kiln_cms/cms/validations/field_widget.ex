defmodule KilnCMS.CMS.Validations.FieldWidget do
  @moduledoc """
  A `FieldDefinition`'s editor `widget` (#2284) must be one its settings offer
  (`KilnCMS.CMS.FieldWidgets.allowed/1`): `radios` on a single select,
  `single_line` on plain text, a plugin type's own, and so on. `nil` (the
  type's default) always passes.

  `KilnCMS.CMS.Changes.ClearWidget` runs first and drops a stored widget the
  write's other settings no longer offer, so what reaches this is a widget the
  write names, or one stored on a field nothing changed.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Changes.ClearWidget

  @impl true
  def validate(changeset, _opts, _context) do
    widget = Ash.Changeset.get_attribute(changeset, :widget)

    if is_nil(widget) do
      :ok
    else
      check(changeset, widget, ClearWidget.allowed(changeset))
    end
  end

  defp check(changeset, widget, allowed) do
    cond do
      widget in allowed ->
        :ok

      widget == "checkboxes" and open_vocabulary?(changeset) ->
        error(
          gettext("checkboxes can't take terms of their own: use tags, or turn off new terms")
        )

      allowed == [] ->
        error(gettext("this field has no choice of editor input"))

      true ->
        error(
          gettext("%{widget} is not an editor input for this field (use one of: %{allowed})",
            widget: widget,
            allowed: Enum.join(allowed, ", ")
          )
        )
    end
  end

  defp open_vocabulary?(changeset) do
    Ash.Changeset.get_attribute(changeset, :field_type) == :select and
      Ash.Changeset.get_attribute(changeset, :multiple) == true and
      Ash.Changeset.get_attribute(changeset, :allow_custom) == true
  end

  defp error(message),
    do: {:error, InvalidAttribute.exception(field: :widget, message: message)}
end
