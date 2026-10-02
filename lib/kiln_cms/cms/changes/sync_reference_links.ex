defmodule KilnCMS.CMS.Changes.SyncReferenceLinks do
  @moduledoc """
  Keeps a record's `kind: :reference` `ContentLink` edges in step with its
  **live** `custom_fields` (#1594). See `KilnCMS.CMS.ContentLinks`.

  Declared on every create, update and destroy of a content resource, and
  decides in an `after_action` — by comparing the stored map before and after
  — rather than at changeset build. Several writers force-change
  `custom_fields` in their own `before_action` (a version restore, the fold of
  a working copy on unpublish), so "is `custom_fields` changing?" asked at
  build time misses exactly the writes that move a reference wholesale.

  A working-copy save (`:save_working_copy`) changes `working_fields`, never
  `custom_fields`, so it writes no edge: draft references are not links.

  The edges are written in the same transaction as the content write, as
  `CMS.Bookkeeping.system/0` — they are the write's consequence, not the
  caller's own act (a scheduled publish has no caller at all). A failure fails
  the write: an edge table that silently disagrees with the field it mirrors
  is the stale snapshot problem over again.

  Destroy: the soft delete (trash) keeps the edges — a restore brings the
  record back with its references. `:purge` removes them.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentLinks

  @impl true
  def change(%{action_type: :destroy} = changeset, _opts, _context) do
    if soft_destroy?(changeset) do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        :ok = ContentLinks.clear(record)
        {:ok, record}
      end)
    end
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if changed?(changeset, record), do: :ok = ContentLinks.reconcile(record)
      {:ok, record}
    end)
  end

  defp changed?(%{action_type: :create}, record),
    do: Map.get(record, :custom_fields) not in [nil, %{}]

  defp changed?(changeset, record),
    do: Map.get(changeset.data, :custom_fields) != Map.get(record, :custom_fields)

  # AshArchival turns the primary destroy into an update that stamps
  # `archived_at`; `:purge` opts out of it and is the only real delete.
  defp soft_destroy?(changeset), do: Map.get(changeset.action, :soft?, false)
end
