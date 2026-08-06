defmodule KilnCMS.CMS.Changes.CancelPendingReleaseItems do
  @moduledoc """
  Releases the content reservations held by a release that is being closed out
  without shipping (#500).

  A `KilnCMS.CMS.ReleaseItem` reserves its content record against every other
  release for as long as it is `:pending` (the partial unique index). Archiving a
  release that never went live has to hand those records back, or a page could
  never be put in another release again — a leak with no UI to find it, because
  the archived release is out of the list by then.

  Runs in `after_action`, inside the archive's own transaction: the release
  moving to `:archived` and its items being freed are one write or neither.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, release ->
      case cancel_pending(release) do
        :ok -> {:ok, release}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp cancel_pending(release) do
    opts = [authorize?: false, tenant: release.org_id]

    with {:ok, items} <-
           KilnCMS.CMS.list_release_items_with_status(release.id, :pending, opts) do
      Enum.reduce_while(items, :ok, &cancel_one(&1, &2, opts))
    end
  end

  defp cancel_one(item, :ok, opts) do
    case KilnCMS.CMS.mark_release_item_cancelled(item, %{}, opts) do
      {:ok, _} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end
end
