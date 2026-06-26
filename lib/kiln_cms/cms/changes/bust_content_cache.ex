defmodule KilnCMS.CMS.Changes.BustContentCache do
  @moduledoc """
  Invalidates the published-content cache (`KilnCMS.Cache`) after any write that
  could change what the public delivery layer serves.

  Attached globally to content create/update/destroy actions, it only busts when
  published content is involved — the record is published *after* the change
  (publish, edit-while-published) or was published *before* it (unpublish,
  archive, soft-delete). Draft-only writes (e.g. autosave) are skipped, so heavy
  editing doesn't churn the cache.

  Invalidation is **per record**, not a full clear: only the affected
  `{type, slug}` keys are dropped (`Cache.bust/2`). A slug edit busts both the
  old and new slug so neither the stale nor the renamed entry lingers.
  """
  use Ash.Resource.Change

  alias KilnCMS.Cache

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if published_involved?(changeset, record), do: bust(changeset, record)
      {:ok, record}
    end)
  end

  # Drop the keys for this record's slug(s). `changeset.data` carries the
  # pre-change slug, `record` the post-change one — busting both covers a slug
  # rename (and collapses to one key when unchanged).
  defp bust(changeset, record) do
    type = to_string(changeset.resource.__kiln_content_type__())

    [changeset.data, record]
    |> Enum.map(&Map.get(&1, :slug))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Cache.bust(type, &1))
  end

  defp published_involved?(changeset, record) do
    state(record) == :published or state(changeset.data) == :published
  end

  defp state(%{state: state}), do: state
  defp state(_), do: nil
end
