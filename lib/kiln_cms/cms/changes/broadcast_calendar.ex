defmodule KilnCMS.CMS.Changes.BroadcastCalendar do
  @moduledoc """
  Tells every open editorial calendar that something it plots has moved.

  `KilnCMSWeb.CalendarLive` renders a projection over `scheduled_at`,
  `unpublish_at`, `published_at`, `due_at` and the release/task dates
  (`KilnCMS.CMS.Calendar`). Without this, an editor with the calendar open sees
  the window as it stood when they loaded it — and the calendar is the surface
  a team looks at *while* someone else is scheduling things, which is exactly
  when a stale grid misleads.

  Attached to the resource actions rather than to the editor's event handlers,
  so a schedule set through the API, by a scheduler, or by another editor's
  LiveView moves the grid the same way. The calendar is a view of the data.

  ## Scoped to one org

  The topic carries the org id. A global topic would wake every tenant's open
  calendar on every other tenant's write — a wasted re-query in the best case,
  and a side channel on how busy a neighbouring site is in the worst.

  ## `after_transaction`, deliberately

  The message is observed by *someone else*, who responds by re-querying. Fired
  from `after_action` it would race the commit: a calendar that re-read inside
  the writing transaction sees the pre-write state and renders it as current.
  Same rule `KilnCMS.CMS.Changes.BroadcastComment` and `BustTypeRegistry`
  follow, and the reason `after_action` was wrong for cache busting too.

  A failed write broadcasts nothing — the `{:error, _}` clause falls through
  untouched — so a chip never moves for a schedule that did not save.
  """
  use Ash.Resource.Change

  @doc "The PubSub topic carrying one org's calendar invalidations."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(org_id), do: "calendar:#{org_id}"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &broadcast/2)
  end

  defp broadcast(_changeset, {:ok, record} = result) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      topic(record.org_id),
      {:calendar_changed, record.id}
    )

    result
  end

  defp broadcast(_changeset, other), do: other
end
