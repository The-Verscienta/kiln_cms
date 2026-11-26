defmodule KilnCMS.Backups.Run.Changes.MarkFiles do
  @moduledoc """
  Marks files of a `KilnCMS.Backups.Run` gone under one key (`mode: :pruned`,
  the `:mark_pruned` action): retention deleted them, from this host's backup
  directory (`"local"`) or from a destination (its key, #2220).

  The new `artifacts` are computed in a `before_action`, declared after
  `get_and_lock_for_update()`, so from the row **as locked**, not from the
  struct the caller read. A writer that rewrites the same row under the same
  lock (`:reevaluate_interrupted`, #2846) therefore can't lose this mark, and
  this mark can't put back artifacts that writer replaced: whichever commits
  second sees the first one's row.

  The arguments are `names` (file names), `key` and `at` (the ISO 8601
  instant recorded with the mark). A media set's parts are one artifact: each
  deleted part is marked, and the artifact itself once none of its parts is
  left to mark. Names that are not artifacts (a checksum sidecar) change
  nothing.
  """
  use Ash.Resource.Change

  @artifact_fields [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]

  @impl true
  def init(opts) do
    case Keyword.get(opts, :mode) do
      :pruned -> {:ok, opts}
      other -> {:error, "MarkFiles needs mode: :pruned, got: #{inspect(other)}"}
    end
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &mark/1)
  end

  defp mark(changeset) do
    names = Ash.Changeset.get_argument(changeset, :names) || []
    key = Ash.Changeset.get_argument(changeset, :key)
    pruned = %{"status" => "pruned", "at" => Ash.Changeset.get_argument(changeset, :at)}

    artifacts = Enum.map(changeset.data.artifacts, &prune_artifact(&1, names, key, pruned))
    Ash.Changeset.force_change_attribute(changeset, :artifacts, artifacts)
  end

  defp prune_artifact(artifact, names, key, pruned) do
    attrs = Map.take(artifact, @artifact_fields)

    case attrs.parts do
      [] ->
        if artifact.name in names, do: put_pruned(attrs, key, pruned), else: attrs

      parts ->
        prune_parts(attrs, parts, names, key, pruned)
    end
  end

  defp prune_parts(attrs, parts, names, key, pruned) do
    parts =
      Enum.map(parts, fn part ->
        if part["name"] in names, do: put_part_pruned(part, key, pruned), else: part
      end)

    attrs = %{attrs | parts: parts}
    if Enum.all?(parts, &part_pruned?(&1, key)), do: put_pruned(attrs, key, pruned), else: attrs
  end

  defp put_pruned(attrs, key, pruned),
    do: %{attrs | destinations: Map.put(attrs.destinations, key, pruned)}

  defp put_part_pruned(part, key, pruned) do
    Map.update(part, "destinations", %{key => pruned}, &Map.put(&1, key, pruned))
  end

  defp part_pruned?(part, key), do: get_in(part, ["destinations", key, "status"]) == "pruned"
end
