defmodule KilnCMS.CMS.Changes.StampDraftSavedAt do
  @moduledoc """
  Stamps `draft_saved_at` alongside a `draft_snapshot` write (the editor's
  crash-recovery working state, T2): the current time when a snapshot is
  present, `nil` when it's being cleared — so `draft_saved_at` is exactly "there
  is unsaved recoverable work, as of this time".
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    saved_at =
      if Ash.Changeset.get_attribute(changeset, :draft_snapshot),
        do: DateTime.utc_now(),
        else: nil

    Ash.Changeset.force_change_attribute(changeset, :draft_saved_at, saved_at)
  end
end
