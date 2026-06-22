defmodule KilnCMS.CMS.Changes.RestoreVersion do
  @moduledoc """
  Restores a Page/Post's content fields to the state captured at a given
  PaperTrail version.

  Versions are tracked in `:changes_only` mode (each stores only what changed),
  so the full state at the target version is reconstructed by replaying — i.e.
  merging — every version's `changes` from creation up to and including the
  target. Only content fields are restored (state/workflow and timestamps are
  left as-is); the restore itself is captured as a new version.
  """
  use Ash.Resource.Change
  require Ash.Query

  @restorable ~w(title slug blocks excerpt seo_title seo_description locale)

  @impl true
  def change(changeset, _opts, _context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    Ash.Changeset.before_action(changeset, &apply_version(&1, version_id))
  end

  defp apply_version(changeset, version_id) do
    version_module = Module.concat(changeset.resource, Version)
    source_id = changeset.data.id

    case fetch_target(version_module, version_id, source_id) do
      {:ok, target} ->
        version_module
        |> replay(source_id, target.version_inserted_at)
        |> restore_fields(changeset)

      :error ->
        Ash.Changeset.add_error(changeset,
          field: :version_id,
          message: "is not a version of this record"
        )
    end
  end

  defp fetch_target(version_module, version_id, source_id) do
    version_module
    |> Ash.Query.filter(id == ^version_id and version_source_id == ^source_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = version} -> {:ok, version}
      _ -> :error
    end
  end

  # Merge every version's changes up to the target, in chronological order, to
  # reconstruct the full attribute set at that point.
  defp replay(version_module, source_id, up_to) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id and version_inserted_at <= ^up_to)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{}, fn version, acc -> Map.merge(acc, version.changes) end)
  end

  defp restore_fields(state, changeset) do
    Enum.reduce(@restorable, changeset, fn key, acc ->
      case Map.fetch(state, key) do
        {:ok, value} ->
          Ash.Changeset.force_change_attribute(acc, String.to_existing_atom(key), value)

        :error ->
          acc
      end
    end)
  end
end
