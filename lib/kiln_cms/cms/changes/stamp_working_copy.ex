defmodule KilnCMS.CMS.Changes.StampWorkingCopy do
  @moduledoc """
  Stamps `working_copy_at` on a `:save_working_copy` write — or clears the
  working copy entirely when nothing in it differs from what is live.

  "As soon as the working copy runs ahead" is the whole state model
  (docs/working-copy.md): a live entry reads **Live · draft** exactly when its
  working title, working body or any held field (`working_fields`, staged by
  `Changes.StageWorkingFields` before this runs) differs from the live row. An
  editor who types a word and deletes it again has not run ahead of anything,
  so that save lands as *no working copy* rather than as a pending change that
  publishes nothing. The text comparison is
  `KilnCMS.CMS.WorkingCopy.same_blocks?/3`, over the dumped trees, so a tree
  loaded from the row and one cast from the editor's params compare on content
  rather than on struct provenance.

  A write that does not supply the title or the body leaves them as the copy
  already had them — the previous copy, or the published text when there was
  none. So a settings-only save on a record with no copy yet starts one whose
  text is the published text, and the stamp never lands beside a `NULL`
  working title that "Publish changes" could not promote.

  Runs at changeset-build time: the accepted `working_title` / `working_blocks`
  are cast by then, and `changeset.data` carries the live row to compare
  against. The `:save_working_copy` action's `optimistic_lock` is what makes
  that struct trustworthy — a stale one is refused at the row.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, _context) do
    basis = WorkingCopy.basis(changeset.data)
    title = text(changeset, :working_title, basis.title)
    blocks = text(changeset, :working_blocks, basis.blocks)
    fields = Ash.Changeset.get_attribute(changeset, :working_fields) || %{}

    if fields == %{} and same_text?(changeset.resource, title, blocks, changeset.data) do
      changeset
      |> Ash.Changeset.force_change_attribute(:working_title, nil)
      |> Ash.Changeset.force_change_attribute(:working_blocks, [])
      |> Ash.Changeset.force_change_attribute(:working_fields, %{})
      |> Ash.Changeset.force_change_attribute(:working_base, %{})
      |> Ash.Changeset.force_change_attribute(:working_copy_at, nil)
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:working_title, title)
      |> Ash.Changeset.force_change_attribute(:working_blocks, List.wrap(blocks))
      |> record_text_base()
      |> Ash.Changeset.force_change_attribute(:working_copy_at, DateTime.utc_now())
    end
  end

  # A copy starting now is based on the live text now: what the lost-update
  # guard (`WorkingCopy.reconcile/1`) compares the live title and body with at
  # publish time. A copy that already existed keeps the base it started from.
  defp record_text_base(%{data: %{working_copy_at: %DateTime{}}} = changeset), do: changeset

  defp record_text_base(changeset) do
    live = changeset.data
    base = Ash.Changeset.get_attribute(changeset, :working_base) || %{}

    text = %{
      "title" => WorkingCopy.live_fingerprint(live, "title"),
      "blocks" => WorkingCopy.live_fingerprint(live, "blocks")
    }

    Ash.Changeset.force_change_attribute(changeset, :working_base, Map.merge(base, text))
  end

  # SUPPLIED, not "changing": Ash elides a value equal to `changeset.data`, so
  # an emptied body saved on a record with no copy yet (`[]` against the
  # column's `[]`) is not a change — and is still the body the editor meant.
  # An elided value equals the data, so `get_attribute/2` reads it back.
  defp text(changeset, name, fallback) do
    if supplied?(changeset, name),
      do: Ash.Changeset.get_attribute(changeset, name),
      else: fallback
  end

  defp supplied?(changeset, name) do
    Ash.Changeset.changing_attribute?(changeset, name) or
      Map.has_key?(changeset.params, name) or
      Map.has_key?(changeset.params, to_string(name))
  end

  defp same_text?(resource, title, blocks, %{title: live_title, blocks: live_blocks}) do
    title == live_title and WorkingCopy.same_blocks?(resource, blocks, live_blocks)
  end

  defp same_text?(_resource, _title, _blocks, _data), do: false
end
