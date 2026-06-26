defmodule KilnCMS.CMS.Changes.CoalesceAutosaveVersions do
  @moduledoc """
  Collapses the run of draft-autosave PaperTrail versions into a single snapshot
  so debounced autosaves don't flood version history (issue #32).

  Draft autosave (`:autosave`) is versioned like any other update, but each
  debounced save would otherwise add a row. After the autosave version is
  committed, this change merges every *trailing* `:autosave` version — those
  recorded since the most recent non-autosave (manual / workflow) version — into
  the newest one, then deletes the now-redundant older autosave rows. Merging
  preserves the cumulative `:changes_only` delta of the whole run, so version
  replay (`RestoreVersion`) stays correct even though intermediate rows are gone.

  Manual saves and workflow transitions write their own distinctly-named
  versions and are never touched, so history stays meaningful while a draft keeps
  exactly one "latest autosaved draft" restore point between manual saves.

  Runs in `after_transaction` (so the just-written version row exists before we
  coalesce) and as a system caller (`authorize?: false`) since version
  update/destroy is otherwise forbidden by `KilnCMS.CMS.VersionPolicies`.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} ->
          coalesce(record)
          result

        _ ->
          result
      end
    end)
  end

  defp coalesce(record) do
    version_module = Module.concat(record.__struct__, Version)

    case trailing_autosave_versions(version_module, record.id) do
      # Nothing to collapse: a single (or zero) trailing autosave version.
      versions when length(versions) <= 1 ->
        :ok

      versions ->
        {keep, superseded} = List.pop_at(versions, -1)

        merged =
          Enum.reduce(versions, %{}, fn version, acc -> Map.merge(acc, version.changes) end)

        Ash.update!(keep, %{changes: merged}, action: :update, authorize?: false)
        Enum.each(superseded, &Ash.destroy!(&1, action: :destroy, authorize?: false))
    end
  end

  # The contiguous run of autosave versions newer than the most recent manual
  # (non-autosave) version, ordered oldest → newest.
  defp trailing_autosave_versions(version_module, source_id) do
    query =
      version_module
      |> Ash.Query.filter(version_source_id == ^source_id and version_action_name == :autosave)
      |> Ash.Query.sort(version_inserted_at: :asc)

    query =
      case latest_manual_version_timestamp(version_module, source_id) do
        nil -> query
        boundary -> Ash.Query.filter(query, version_inserted_at > ^boundary)
      end

    Ash.read!(query, authorize?: false)
  end

  defp latest_manual_version_timestamp(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id and version_action_name != :autosave)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      version -> version.version_inserted_at
    end
  end
end
