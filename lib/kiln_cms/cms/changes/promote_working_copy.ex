defmodule KilnCMS.CMS.Changes.PromoteWorkingCopy do
  @moduledoc """
  The write behind `:publish_changes` (docs/working-copy.md): moves the working
  copy's title and blocks into the live columns and clears the working copy.

  The rest of the action is what makes that a *publish* rather than an edit —
  the search text, embedding, artifacts, the `updated` webhook and the
  `published_version_id` pointer all move with it. What deliberately does
  **not** move is `published_at`, and no workflow email goes out: the same URL,
  the same date, no notification. A correction inside a live entry is not the
  entry going out.

  Applied at changeset-build time rather than in a `before_action`, so the
  action's plain `validate`s — the alt-text and claim gates, keyed on
  `changing(:blocks)` — judge the text that is about to go live, the way they
  do on `:update`. That reads the working copy off `changeset.data`, which the
  action's `optimistic_lock` guarantees is the row: a struct that predates the
  latest autosave fails the lock instead of publishing yesterday's draft.

  A record with no working copy is refused here with a field error as well as
  at the row (`change filter`): the row filter is the race guard, this is the
  message.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data do
      %{working_copy_at: %DateTime{}, working_title: title, working_blocks: blocks} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:title, title)
        |> Ash.Changeset.force_change_attribute(:blocks, blocks || [])
        |> Ash.Changeset.force_change_attribute(:working_title, nil)
        |> Ash.Changeset.force_change_attribute(:working_blocks, [])
        |> Ash.Changeset.force_change_attribute(:working_copy_at, nil)

      _no_working_copy ->
        Ash.Changeset.add_error(changeset,
          field: :working_copy_at,
          message: "has no unpublished changes to publish"
        )
    end
  end
end
