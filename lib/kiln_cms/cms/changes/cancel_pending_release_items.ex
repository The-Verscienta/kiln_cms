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

  Reads the pending items as the archiving editor (#1659) — archiving already
  requires the editor grant `ReleaseItem` reads with — and marks them
  cancelled as `KilnCMS.CMS.Bookkeeping.system/0`, since `:mark_cancelled` is
  a `mark_*` write no person may reach. The read uses `authorize_with:
  :error`: a refused read would filter to "nothing pending", archive the
  release, and leave its items reserving their content forever.

  An item another writer freed between the read and its cancel
  (`KilnCMS.CMS.StrandedReleaseItemSweep`, #3072) is a stale miss on
  `:mark_cancelled`'s compare-and-swap. That item is free already, which is
  all the archive needs, so the archive goes on; any other error still
  aborts the archive.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, release ->
      case cancel_pending(release, context) do
        :ok -> {:ok, release}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp cancel_pending(release, context) do
    read_opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.merge(tenant: release.org_id, authorize_with: :error)

    # `rollback_on_error?: false`: an error comes back to `cancel_one/3`,
    # which decides, rather than rolling the archive back from inside the
    # write. (Ash already hands a stale miss back without a rollback; this
    # keeps that from depending on it.)
    write_opts = [
      actor: KilnCMS.CMS.Bookkeeping.system(),
      tenant: release.org_id,
      rollback_on_error?: false
    ]

    with {:ok, items} <-
           KilnCMS.CMS.list_release_items_with_status(release.id, :pending, read_opts) do
      Enum.reduce_while(items, :ok, &cancel_one(&1, &2, write_opts))
    end
  end

  defp cancel_one(item, :ok, opts) do
    case KilnCMS.CMS.mark_release_item_cancelled(item, %{}, opts) do
      {:ok, _} ->
        {:cont, :ok}

      {:error, reason} ->
        # Freed by another writer since the read: free is what archiving needs.
        if KilnCMS.CMS.Releases.stale?(reason),
          do: {:cont, :ok},
          else: {:halt, {:error, reason}}
    end
  end
end
