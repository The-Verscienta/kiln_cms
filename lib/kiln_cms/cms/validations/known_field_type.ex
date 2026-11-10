defmodule KilnCMS.CMS.Validations.KnownFieldType do
  @moduledoc """
  A `FieldDefinition`'s `field_type` must be registered: one of the built-in
  value types or a plugin-contributed `Kiln.FieldType`
  (`KilnCMS.CMS.FieldTypes.names/0`). The attribute has no `one_of` (see its
  comment), so this is the write-side check.

  A create or update naming an unregistered type is refused. So is any update
  of a row whose stored type this release does not know
  (`FieldDefinition.unknown_type?/1`, #2605), whatever it changes, with what
  to do instead: its stored values are in that type's shape, so such a field
  can only be deleted, or kept until its type is back (no in-place retype).
  The one exception is a rename of a sibling its condition reads, whose rule
  `Changes.SyncFieldValues` rewrites. A destroy is not validated.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldDefinition

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    cond do
      # A rename's rewrite of the rules that read the renamed field
      # (`Changes.SyncFieldValues`) touches only `visible_when` and
      # `required_when`, and must reach every dependent.
      changeset.context[:kiln_condition_rename] == true and
          FieldDefinition.unknown_type?(changeset.data) ->
        :ok

      changeset.action_type == :update and FieldDefinition.unknown_type?(changeset.data) ->
        refuse(
          changeset.data.field_type,
          "is not a field type this release knows, so the field can't be changed: " <>
            "delete it, or upgrade Kiln or reinstall the plugin that provides it"
        )

      is_nil(type) ->
        :ok

      FieldDefinition.unknown_type?(%{field_type: type}) ->
        refuse(type, "is not a registered field type")

      true ->
        :ok
    end
  end

  defp refuse(type, message) do
    {:error,
     InvalidAttribute.exception(field: :field_type, message: message, value: to_string(type))}
  end
end
