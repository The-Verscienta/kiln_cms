defmodule KilnCMS.CMS.Validations.ItemTypeInUse do
  @moduledoc """
  Refuses to destroy an **item type** of a flexible field (#2282) while any
  stored item of that type exists, unless the destroy passes
  `purge_items?: true` (`Changes.SyncFieldValues` then removes the items).

  An item type is the only definition whose destroy loses *content an editor
  authored* without the admin naming it: the items sit in documents across the
  site, under a path through possibly nested flexible fields
  (`KilnCMS.CMS.FlexiblePath`), and a type name is unique only within its own
  flexible field. A sub-field's destroy purges its key like a group's does.

  A flexible field's own destroy (and a nested one's) is **not** guarded: it
  is a group's behavior, the key and every item below go, and the database
  cascade that removes its item types does not pass through this validation
  at all. Every other definition passes untouched.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.Changes.SyncFieldValues
  alias KilnCMS.CMS.FlexiblePath

  @impl true
  def validate(%{data: %{flex_of_id: flex_id} = item_type} = changeset, _opts, _context)
      when not is_nil(flex_id) do
    if Ash.Changeset.get_argument(changeset, :purge_items?) == true,
      do: :ok,
      else: guard(item_type)
  end

  def validate(_changeset, _opts, _context), do: :ok

  # Only an owner that is genuinely gone (it took its rows, and so every item,
  # with it) lets the destroy through unguarded; a failed read, a chain past
  # the depth cap or an unresolvable table refuses, as `items_exist?/3` does.
  #
  # Check-then-act: an item can be saved between this check and the post-commit
  # purge in `Changes.SyncFieldValues`; the purge then removes it with the type.
  defp guard(item_type) do
    case FlexiblePath.item_path_detailed(item_type, item_type.org_id) do
      {:ok, top, steps} -> guard_items(item_type, top, steps)
      {:error, :gone} -> :ok
      {:error, _unreadable_or_too_deep} -> refuse(item_type, :unverifiable)
    end
  end

  defp guard_items(item_type, top, steps) do
    case SyncFieldValues.target(top) do
      {:ok, table, filter, params} ->
        if FlexiblePath.items_exist?(table, steps, {filter, params}),
          do: refuse(item_type, :in_use),
          else: :ok

      :error ->
        refuse(item_type, :unverifiable)
    end
  end

  defp refuse(item_type, :in_use) do
    {:error,
     InvalidAttribute.exception(
       field: :name,
       message:
         "can't be deleted while documents hold #{item_type.name} items; " <>
           "remove them first, or delete with purge_items? to remove them with the type"
     )}
  end

  defp refuse(item_type, :unverifiable) do
    {:error,
     InvalidAttribute.exception(
       field: :name,
       message:
         "can't be deleted: whether documents hold #{item_type.name} items could not be checked; " <>
           "try again, or delete with purge_items? to remove any with the type"
     )}
  end
end
