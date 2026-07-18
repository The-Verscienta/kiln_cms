defmodule KilnCMS.Firing.PointInTime do
  @moduledoc """
  Point-in-time delivery (#338): the published artifact for a document **as it
  was on a past date**, reconstructed from PaperTrail history and re-fired in
  memory.

  For compliance/audit ("what did our published guidance say on 2026-03-01,
  provably"): find the last `:publish` / `:publish_scheduled` version at or
  before the requested moment, replay the `:changes_only` version history up to
  it to reconstruct the full published state (mirroring
  `KilnCMS.CMS.Changes.RestoreVersion`), and re-fire that state through the
  firing engine in `:preview` mode — no DB write, no cache. It produces the same
  per-surface artifacts (`:web` / `:json` / `:json_ld`) as live delivery.

  Phase 1 scope: lookup is by a document's id (the caller resolves it from the
  *current* record), so content that has since been unpublished/removed isn't
  reachable; and a temporary unpublish "dark window" still reports the most
  recent publish. Id-addressable history and dark-window awareness are later
  phases.
  """
  require Ash.Query

  alias KilnCMS.Firing.Engine

  @publish_actions [:publish, :publish_scheduled]

  @doc """
  The fired `surface` body for `resource`/`id` as published at or before
  `as_of`, plus the effective publish time. `{:error, :not_published}` when
  nothing was published by then.
  """
  @spec read(Ash.UUID.t(), module(), Ash.UUID.t(), atom(), DateTime.t()) ::
          {:ok, map(), DateTime.t()} | {:error, :not_published}
  def read(org_id, resource, id, surface, %DateTime{} = as_of) do
    version_module = Module.concat(resource, Version)

    # Version rows inherit the source's tenant (epic #336), so the history reads
    # are scoped to this org; the rebuilt document is re-stamped with `org_id` so
    # the in-memory re-fire stays in the right tenant.
    case last_publish(version_module, id, as_of, org_id) do
      {:ok, published_at} ->
        {:ok, artifacts} =
          version_module
          |> replay(id, published_at, org_id)
          |> build_document(resource, id, org_id)
          |> Engine.fire(mode: :preview)

        {:ok, Map.fetch!(artifacts, surface), published_at}

      :error ->
        {:error, :not_published}
    end
  end

  # The most recent publish at or before `as_of` — its timestamp bounds the replay.
  defp last_publish(version_module, id, as_of, org_id) do
    version_module
    |> Ash.Query.filter(
      version_source_id == ^id and version_inserted_at <= ^as_of and
        version_action_name in ^@publish_actions
    )
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false, tenant: org_id)
    |> case do
      {:ok, [version]} -> {:ok, version.version_inserted_at}
      _ -> :error
    end
  end

  # Reconstruct the full attribute state at `up_to` by merging every version's
  # `changes` in chronological order (`:changes_only` tracking).
  defp replay(version_module, id, up_to, org_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^id and version_inserted_at <= ^up_to)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false, tenant: org_id)
    |> Enum.reduce(%{}, fn version, acc -> Map.merge(acc, version.changes) end)
  end

  # A fireable document struct of `resource` from the replayed (string-keyed)
  # state. The firing engine reads `.blocks` (via `TypedBlocks.to_typed`, which
  # tolerates the stored map shape), `.title`/`.slug`, and derives the type from
  # the struct module. Restricted to real attributes so a stray change key can't
  # blow up on `String.to_existing_atom`.
  defp build_document(state, resource, id, org_id) do
    names = resource |> Ash.Resource.Info.attributes() |> MapSet.new(&to_string(&1.name))

    attrs =
      for {key, value} <- state, MapSet.member?(names, key), into: %{} do
        {String.to_existing_atom(key), value}
      end

    # `org_id` is a version column (attributes_as_attributes), not in the freeform
    # `changes` map, so stamp it explicitly for the in-memory re-fire.
    struct(resource, attrs |> Map.put(:id, id) |> Map.put(:org_id, org_id))
  end
end
