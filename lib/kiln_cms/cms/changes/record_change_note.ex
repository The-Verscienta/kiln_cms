defmodule KilnCMS.CMS.Changes.RecordChangeNote do
  @moduledoc """
  Stores *why* an edit was made on the edit's own version row
  (`change_note`, `KilnCMS.CMS.ChangeNotes` has the rule and the setting).

  Applied once, in the shared Content macro's `changes` block, on every update
  action. Only the actions that take a `change_note` argument (`:update`,
  `:publish`, `:publish_changes`, `:restore_version`) can carry one; the rest
  pass through untouched.

  ## Outcome

  The argument, trimmed, goes to
  `changeset.context[:paper_trail_metadata][:change_note]`, which
  AshPaperTrail copies into the version it writes in the same transaction. A
  blank note is no note.

  A missing note is an error on `:change_note` only when the changeset carries
  the `require_change_note` context marker **and** the site asks for a note on
  the record's type (`ChangeNotes.required?/2`). The editor sets the marker on
  a draft's Save and on Publish changes, where it shows the input. Every other
  writer — the API, MCP, the reverse field, a scheduled publish, an internal
  job — may send a note and is never refused for leaving it out, the same
  posture `RecordChangeSeverity` takes with the severity.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ChangeNotes
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Resource.Info.action_input?(changeset.resource, changeset.action.name, :change_note) do
      decide(changeset)
    else
      changeset
    end
  end

  defp decide(changeset) do
    case ChangeNotes.normalize(Ash.Changeset.get_argument(changeset, :change_note)) do
      nil ->
        # In a hook, so a form's validation (which runs the changes but not the
        # hooks) never shows the error while the editor is still typing.
        if changeset.context[:require_change_note] == true,
          do: Ash.Changeset.before_action(changeset, &check_required/1),
          else: changeset

      note ->
        record(changeset, note)
    end
  end

  defp check_required(changeset) do
    if ChangeNotes.required?(changeset.data.org_id, ContentTypes.type_name_for(changeset)),
      do: missing(changeset),
      else: changeset
  end

  defp record(changeset, note) do
    metadata = Map.put(changeset.context[:paper_trail_metadata] || %{}, :change_note, note)
    Ash.Changeset.set_context(changeset, %{paper_trail_metadata: metadata})
  end

  defp missing(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :change_note,
      message: "say why you made this change"
    )
  end
end
