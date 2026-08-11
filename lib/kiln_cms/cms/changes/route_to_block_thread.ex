defmodule KilnCMS.CMS.Changes.RouteToBlockThread do
  @moduledoc """
  Every comment on the same `content_type`/`content_id`/`block_id` belongs to
  **one** thread (#404 — the issue's own wording is "a comment thread anchored
  to a block id", singular). The first comment on a block becomes the thread
  (`thread_id` stays nil); this routes every comment after it to that same
  root, server-side — the caller only ever says "add a comment to this
  block", never which thread, so there is nothing for it to get wrong.

  Reads the block's existing comments (`authorize?: false` — routing is not a
  read the caller needs their own grant for) rather than trusting anything
  from the request. Two concurrent first comments on a brand-new block could
  each see none yet and both become roots; accepted as a rare, low-stakes race
  for a low-concurrency editorial feature rather than adding a partial unique
  index for it.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS

  @impl true
  def change(changeset, _opts, _context) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    content_id = Ash.Changeset.get_attribute(changeset, :content_id)
    block_id = Ash.Changeset.get_attribute(changeset, :block_id)

    case CMS.list_comments_for_block!(content_type, content_id, block_id,
           authorize?: false,
           tenant: changeset.tenant
         ) do
      [] ->
        changeset

      comments ->
        root = Enum.find(comments, &is_nil(&1.thread_id)) || List.first(comments)
        Ash.Changeset.force_change_attribute(changeset, :thread_id, root.id)
    end
  end
end
