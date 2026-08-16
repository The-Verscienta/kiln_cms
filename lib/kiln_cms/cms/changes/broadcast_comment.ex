defmodule KilnCMS.CMS.Changes.BroadcastComment do
  @moduledoc """
  Tells the shared preview — and every editor open on the document — that a
  block's comment thread changed (#802).

  `KilnCMSWeb.PreviewLive` shows a pin on every block carrying an unresolved
  thread. Without this, a stakeholder watching the preview while an editor
  works would see that set only as it stood when they opened the page.

  Attached to the `Comment` resource's own actions rather than to the editor's
  event handlers, so a comment added through the API moves the pins too — the
  preview is a view of the data, not of one LiveView's actions.

  ## Two topics, two audiences

  * `KilnCMSWeb.PreviewLive.topic/2` — the pop-out preview's pins.
  * `KilnCMS.Collab.topic/2` (`content:<kind>:<id>`) — the *editors*' own
    per-block thread counts. That topic already carries block ops, so every
    open editor is subscribed to it; the gutter needs no subscription of its
    own. Its `{:block_thread_changed, block_id}` is the discussion sibling of
    `KilnCMS.CMS.Changes.BroadcastTaskBlock`'s `{:block_task_changed, _}`.

  Both are fire-and-forget and loss-tolerant: a dropped message costs a stale
  count until the next reload, never a lost comment.

  ## `after_transaction`, deliberately

  The broadcast is *observed by someone else*, so it must not fire before the
  row commits: a `PreviewLive` that re-read the thread set inside the writing
  transaction would see the pre-write state and cache it. Same rule
  `KilnCMS.CMS.Changes.BustTypeRegistry` follows for feeds.

  A failed write broadcasts nothing — the `{:error, _}` clause falls through
  untouched — so a pin never appears for a comment that did not save.
  """
  use Ash.Resource.Change

  alias KilnCMS.Collab

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &broadcast/2)
  end

  defp broadcast(_changeset, {:ok, comment} = result) do
    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic(comment.content_type, comment.content_id),
      {:preview_comments_changed, comment.block_id}
    )

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      Collab.topic(comment.content_type, comment.content_id),
      {:block_thread_changed, comment.block_id}
    )

    result
  end

  defp broadcast(_changeset, other), do: other
end
