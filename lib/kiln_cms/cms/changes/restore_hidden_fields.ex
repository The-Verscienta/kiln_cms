defmodule KilnCMS.CMS.Changes.RestoreHiddenFields do
  @moduledoc """
  Keeps the custom fields an editor cannot see out of harm's way on their write
  (#2281).

  An editor under a read restriction (`field_read_grants`) is served a record
  with the private custom fields they may not read left out. Every write
  rebuilds `custom_fields` from the record it was handed
  (`Changes.ApplyCustomFields` merges the payload over `changeset.data`), and a
  held working copy is promoted or compared as a whole map — so a write built on
  the masked record would store the map **without** the hidden keys and wipe
  them. This change runs BEFORE `ApplyCustomFields` (declared on the actions ahead of it, since
  an action's own changes run before the resource's global ones) and puts the hidden keys'
  stored values back into `changeset.data`, in `custom_fields` and in the
  working copy's held `custom_fields`, so the editor's save leaves them
  byte-identical in the row and in the version diff.

  The values come from a fresh read of the row (the one narrow
  `authorize?: false` read `Changes.FoldWorkingCopy` also makes: the row the
  caller's write was already authorized for, selecting two columns, none of it
  leaving the changeset). A read that fails or finds no row fails the write
  closed.

  A write carrying no hidden keys' worth of restriction — an admin, a system
  write, an editor with no read restriction or one hiding nothing — is passed
  through untouched and costs nothing.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.CMS.Changes.EnforceCustomFieldGrants

  @impl true
  def change(%{action_type: :update} = changeset, _opts, %{actor: %{} = actor}) do
    case EnforceCustomFieldGrants.restriction(changeset, actor) do
      %{hidden: [_ | _] = hidden} -> restore(changeset, hidden)
      _none -> changeset
    end
  end

  def change(changeset, _opts, _context), do: changeset

  # A `can?` probe (the MCP tool list, a policy-driven control) builds this
  # action on a blank record: nothing stored to put back, and nothing to fail.
  defp restore(%{data: %{id: nil}} = changeset, _hidden), do: changeset

  defp restore(%{data: %{id: id, org_id: org_id}, resource: resource} = changeset, hidden) do
    # authorize?: false — see the moduledoc.
    raw =
      resource
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.select([:custom_fields, :working_fields])
      |> Ash.read_one(authorize?: false, tenant: org_id)

    case raw do
      {:ok, %{} = row} ->
        %{changeset | data: patch(changeset.data, row, hidden)}

      _unreadable ->
        Ash.Changeset.add_error(changeset,
          field: :custom_fields,
          message: "could not be checked against your field access"
        )
    end
  end

  # `data` may be the live row or the working view of it (the probe
  # `Changes.StageWorkingFields` builds); each field is restored from whichever
  # of the stored maps the handed one matches once the hidden keys are set aside.
  defp patch(data, row, hidden) do
    live = stringify(row.custom_fields || %{})
    held = row.working_fields |> held_custom_fields()

    custom_fields = stringify(data.custom_fields || %{})

    source =
      if held != nil and Map.drop(custom_fields, hidden) == Map.drop(held, hidden) and
           Map.drop(custom_fields, hidden) != Map.drop(live, hidden), do: held, else: live

    data = %{data | custom_fields: restore_keys(custom_fields, source, hidden)}

    case data.working_fields do
      %{"custom_fields" => %{} = in_data} = fields when held != nil ->
        %{
          data
          | working_fields:
              Map.put(fields, "custom_fields", restore_keys(stringify(in_data), held, hidden))
        }

      _no_held_map ->
        data
    end
  end

  defp held_custom_fields(%{"custom_fields" => %{} = map}), do: stringify(map)
  defp held_custom_fields(_fields), do: nil

  defp restore_keys(map, source, hidden) do
    map
    |> Map.drop(hidden)
    |> Map.merge(Map.take(source, hidden))
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
