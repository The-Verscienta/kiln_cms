defmodule KilnCMS.Notifications.Changes.Announce do
  @moduledoc """
  Tells the recipient's open consoles that one of their notifications changed
  (#1320), so a bell badge and an inbox list follow a read that happened
  somewhere else.

  Attached to `KilnCMS.Notifications.Notification`'s update actions rather than
  called from the bell and the inbox: reading a notification on a phone has to
  drop the badge on the desktop, and a session that did not make the change is
  precisely the one that cannot know about it. It hangs off the resource for
  the same reason `KilnCMS.CMS.Changes.BroadcastComment` does — the count is a
  view of the data, not of one LiveView's clicks, so an API or a future sweep
  moves it too.

  The create side is announced by `KilnCMS.Notifications.record_in_app/1`
  instead, which is the only caller of `:notify` and already the one place that
  knows a row was written.

  ## `after_transaction`, and a content-free message

  Post-commit, because the subscriber re-reads: a session that re-read inside
  the writing transaction would see the pre-write state and cache it. The
  `{:error, _}` clause falls through untouched, so a failed write announces
  nothing and no badge moves for a read that did not save.

  The message carries nothing — see `KilnCMS.Notifications.topic/1` for why
  every subscriber re-reads under its own actor and tenant rather than being
  handed a row.
  """
  use Ash.Resource.Change

  alias KilnCMS.Notifications

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &announce/2)
  end

  defp announce(_changeset, {:ok, notification} = result) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Notifications.topic(notification.user_id),
      :notifications_changed
    )

    result
  end

  defp announce(_changeset, other), do: other
end
