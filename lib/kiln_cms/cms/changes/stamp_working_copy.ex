defmodule KilnCMS.CMS.Changes.StampWorkingCopy do
  @moduledoc """
  Stamps `working_copy_at` on a `:save_working_copy` write — or clears the
  working copy entirely when the text being saved is the text that is live.

  "As soon as the working copy runs ahead" is the whole state model
  (docs/working-copy.md): a live entry reads **Live · draft** exactly when its
  working text differs from its published text. An editor who types a word and
  deletes it again has not run ahead of anything, so that save lands as *no
  working copy* rather than as a pending change that publishes nothing. The
  comparison is `KilnCMS.CMS.WorkingCopy.same_blocks?/3`, over the dumped
  trees, so a tree loaded from the row and one cast from the editor's params
  compare on content rather than on struct provenance.

  Runs at changeset-build time: the accepted `working_title` / `working_blocks`
  are cast by then, and `changeset.data` carries the live `title` / `blocks` to
  compare against. The `:save_working_copy` action's `optimistic_lock` is what
  makes that struct trustworthy — a stale one is refused at the row.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, _context) do
    title = Ash.Changeset.get_attribute(changeset, :working_title)
    blocks = Ash.Changeset.get_attribute(changeset, :working_blocks)

    if same_text?(changeset.resource, title, blocks, changeset.data) do
      changeset
      |> Ash.Changeset.force_change_attribute(:working_title, nil)
      |> Ash.Changeset.force_change_attribute(:working_blocks, [])
      |> Ash.Changeset.force_change_attribute(:working_copy_at, nil)
    else
      Ash.Changeset.force_change_attribute(changeset, :working_copy_at, DateTime.utc_now())
    end
  end

  defp same_text?(resource, title, blocks, %{title: live_title, blocks: live_blocks}) do
    title == live_title and WorkingCopy.same_blocks?(resource, blocks, live_blocks)
  end

  defp same_text?(_resource, _title, _blocks, _data), do: false
end
