defmodule KilnCMS.CMS.Changes.BroadcastTaskBlock do
  @moduledoc """
  Tells everyone open on a document that its task set changed, so a block's
  gutter count moves for every editor rather than only the one who clicked.

  The discussion twin of `KilnCMS.CMS.Changes.BroadcastComment` — same reason
  it hangs off the resource's actions rather than the editor's event handlers:
  a task assigned through the API or completed by `AutoCompleteTasks` on
  publish moves the same counts, because the gutter is a view of the data, not
  of one LiveView's clicks.

  Rides `KilnCMS.Collab.topic/2` (`content:<kind>:<id>`), the topic every
  editor of the document is already subscribed to for block ops — no new topic,
  no new subscription, native `Phoenix.PubSub` only.

  ## What gets broadcast

  `{:block_task_changed, block_id}`, where `block_id` may be `nil`: a
  content-level task is still a change to *this document's* task list, and a
  peer's task panel should follow it. Subscribers that only care about gutter
  pins can ignore the `nil` case; ones showing the document's task list handle
  both alike.

  **Re-anchoring broadcasts twice** — moving a task from block A to block B
  emits both ids, because A's pin has to lose the task at the same moment B's
  gains it. One message naming only the new block would leave a phantom count
  on A until reload.

  ## `after_transaction`, deliberately

  The broadcast is observed by *other* sessions, so it must not fire before the
  row commits: a peer that re-read tasks inside the writing transaction would
  read the pre-write state and cache it. Same rule `BroadcastComment` follows.
  A failed write broadcasts nothing — the `{:error, _}` clause falls through
  untouched — so a count never moves for a task that did not save.

  ### The one case that hook cannot cover

  `Changes.AutoCompleteTasks` completes a record's open tasks from inside the
  *publish* action's transaction. An inner action nested in an outer
  transaction doesn't open one of its own, so this hook runs when the
  completion finishes rather than when the publish commits — a peer that
  re-reads on the message can still see the task open, and stays one count
  behind until the next event.

  Left as-is deliberately: these messages are advisory and at-most-once by
  design (§7 of the plan), the editor doing the publishing reloads its own
  tasks on the publish result anyway, and the alternative — threading
  notifications out of the outer action — would make every task write pay for
  one path's ordering. Worth knowing before treating a stale peer count after
  publish as a lost message.
  """
  use Ash.Resource.Change

  alias KilnCMS.Collab

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &broadcast/2)
  end

  defp broadcast(changeset, {:ok, task} = result) do
    for block_id <- Enum.uniq([task.block_id | previous_block_ids(changeset)]) do
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        # `content_type` is the string form of the editor's `kind` atom
        # (`to_string(kind)` at the call site), so it interpolates to the same
        # topic the editor subscribed with — the assumption `BroadcastComment`
        # already makes for the preview topic.
        Collab.topic(task.content_type, task.content_id),
        {:block_task_changed, block_id}
      )
    end

    result
  end

  defp broadcast(_changeset, other), do: other

  # On an update, `changeset.data` still carries the pre-write row, so this is
  # the block the task is moving *off*. On a create there is no previous
  # anchor: `data` is an empty struct whose nil `block_id` would otherwise be
  # broadcast as a spurious "content-level tasks changed" alongside the real one.
  defp previous_block_ids(%Ash.Changeset{action_type: :update, data: %{block_id: previous}}),
    do: [previous]

  defp previous_block_ids(_changeset), do: []
end
