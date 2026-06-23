defmodule KilnCMS.CMS.Changes.BustContentCache do
  @moduledoc """
  Invalidates the published-content cache (`KilnCMS.Cache`) after any write that
  could change what the public delivery layer serves.

  Attached globally to content create/update/destroy actions, it only busts when
  published content is involved — the record is published *after* the change
  (publish, edit-while-published) or was published *before* it (unpublish,
  archive, soft-delete). Draft-only writes (e.g. autosave) are skipped, so heavy
  editing doesn't churn the cache.
  """
  use Ash.Resource.Change

  alias KilnCMS.Cache

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if published_involved?(changeset, record), do: Cache.bust_published()
      {:ok, record}
    end)
  end

  defp published_involved?(changeset, record) do
    state(record) == :published or state(changeset.data) == :published
  end

  defp state(%{state: state}), do: state
  defp state(_), do: nil
end
