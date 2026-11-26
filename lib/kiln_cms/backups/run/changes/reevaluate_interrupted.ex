defmodule KilnCMS.Backups.Run.Changes.ReevaluateInterrupted do
  @moduledoc """
  The guard of `KilnCMS.Backups.Run`'s `:reevaluate_interrupted` action
  (#2846): an imported row that `KilnCMS.Backups.Importer` recorded as
  "Interrupted" is rewritten, once, when its stamp turned out to have
  finished after all.

  It runs in a `before_action`, declared after `get_and_lock_for_update()`,
  so it judges the row as locked for the rest of the transaction, not the
  struct the importer listed. The row must still be:

    * `origin: :imported`, `failed`, with the importer's Interrupted error
      (`KilnCMS.Backups.Importer.interrupted_message/0`). A row rewritten
      meanwhile (a second importer on another node) no longer is;
    * free of any `pruned` mark, on an artifact or a part, under any key.
      Retention marks what it deleted (`:mark_pruned`, locked the same way),
      and the importer's listing predates that deletion: rewriting would
      record deleted files as present.

  Anything else is refused with `Ash.Error.Changes.StaleRecord` and nothing
  is written. On success the log gains one line saying why. `Normalize` runs
  in the change body, before this hook, so the log is capped here with
  `KilnCMS.Backups.Log.cap/1` directly.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.{Importer, Log}

  @message "Re-evaluated: the stamp's .partial files are gone and its set is complete"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &reevaluate/1)
  end

  defp reevaluate(%{data: run} = changeset) do
    if interrupted?(run) and not pruned?(run.artifacts) do
      entry = %{at: DateTime.utc_now(), level: :info, step: "import", message: @message}
      Ash.Changeset.force_change_attribute(changeset, :log, Log.cap((run.log || []) ++ [entry]))
    else
      Ash.Changeset.add_error(
        changeset,
        Ash.Error.Changes.StaleRecord.exception(resource: changeset.resource)
      )
    end
  end

  defp interrupted?(run),
    do:
      run.origin == :imported and run.status == :failed and
        run.error == Importer.interrupted_message()

  defp pruned?(artifacts) do
    Enum.any?(artifacts || [], fn artifact ->
      marked?(artifact.destinations) or
        Enum.any?(artifact.parts || [], &marked?(&1["destinations"]))
    end)
  end

  defp marked?(%{} = destinations),
    do: Enum.any?(destinations, fn {_key, entry} -> pruned_entry?(entry) end)

  defp marked?(_none), do: false

  defp pruned_entry?(%{"status" => "pruned"}), do: true
  defp pruned_entry?(_entry), do: false
end
