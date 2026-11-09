defmodule KilnCMS.CMS.Changes.ClearWidget do
  @moduledoc """
  Clears a `FieldDefinition`'s editor `widget` (#2284) once the field's other
  settings stop offering it (`KilnCMS.CMS.FieldWidgets.allowed/1`): a select
  retyped to text, a single select made `multiple`, plain text made rich, an
  open vocabulary (`allow_custom`) switched on under checkboxes.

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: the fields admin
  shows only the widgets the posted settings offer, so changing those
  settings would otherwise leave a stored widget on a field that can no
  longer render it. Only when the write does not name a widget itself,
  though: an explicit widget the field doesn't offer is a mistake to report
  (`KilnCMS.CMS.Validations.FieldWidget`), not one to tidy away. "Names" means
  the input carries the key, even with the value already stored — Ash drops
  such a change, and clearing it here would hide the conflict.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.FieldWidgets

  @impl true
  def change(changeset, _opts, _context) do
    widget = Ash.Changeset.get_attribute(changeset, :widget)

    if is_nil(widget) or given?(changeset) or widget in allowed(changeset) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :widget, nil)
    end
  end

  @doc false
  # Whether this write names a widget: as an accepted change, or as input Ash
  # dropped because it equals the stored value.
  @spec given?(Ash.Changeset.t()) :: boolean()
  def given?(changeset) do
    params = changeset.params || %{}

    Ash.Changeset.changing_attribute?(changeset, :widget) or
      Map.has_key?(params, :widget) or Map.has_key?(params, "widget")
  end

  @doc false
  # The widgets the field offers once this write lands: plugin types are asked
  # with the definition they will see in the editor, not a bare changeset.
  @spec allowed(Ash.Changeset.t()) :: [String.t()]
  def allowed(changeset) do
    {:ok, definition} = Ash.Changeset.apply_attributes(changeset, force?: true)
    FieldWidgets.allowed(definition)
  end
end
