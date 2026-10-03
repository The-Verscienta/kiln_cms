defmodule KilnCMS.I18n.Changes.ApplySharedFields do
  @moduledoc """
  The body of a content resource's internal `:sync_shared_fields` action
  (#1327): force-changes the values `KilnCMS.I18n.SharedFields.plan/3`
  computed for one locale variant.

  The values ride in the changeset **context** (`shared_fields:`), not in an
  argument, so the action has no input any HTTP surface could fill; it is not
  routed anywhere either. Only the attributes a sync can produce are applied —
  the shareable record attributes, `custom_fields`, `blocks`, and the three
  working-copy columns a pending copy is kept in step with. Anything else in
  the map is ignored.
  """
  use Ash.Resource.Change

  alias KilnCMS.I18n.FieldLocalization

  @working_copy [:working_blocks, :working_fields, :working_base]

  @impl true
  def change(changeset, _opts, _context) do
    allowed =
      FieldLocalization.shareable_attributes() ++ [:custom_fields, :blocks] ++ @working_copy

    changeset.context
    |> Map.get(:shared_fields, %{})
    |> Enum.filter(fn {name, _value} ->
      name in allowed and Ash.Resource.Info.attribute(changeset.resource, name)
    end)
    |> Enum.reduce(changeset, fn {name, value}, acc ->
      Ash.Changeset.force_change_attribute(acc, name, value)
    end)
  end
end
