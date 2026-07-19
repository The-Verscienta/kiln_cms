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
  # Archive and soft-delete (:destroy, AshArchival) leave the published state
  # too — a removed document must stop appearing in the historical index from
  # that moment. (Hard purges are filtered at entry time: their version rows
  # survive, but re-exposing deliberately erased content would be a privacy
  # regression.)
  @unpublish_actions [:unpublish, :unpublish_scheduled, :archive, :destroy]

  @doc """
  The **collection view as of a date** (#338 phase 2): every document of
  `resource` that was published at `as_of`, as lightweight index entries

      %{id, slug, title, published_at}

  reconstructed from version history (title/slug as they were at that
  document's last publish ≤ `as_of`). A document unpublished before `as_of`
  is excluded — unlike the single-document `read/5`, an index that listed
  since-removed content would misrepresent the site as it stood. Bounded by
  `limit` (newest publishes first).
  """
  @spec index(Ash.UUID.t(), module(), DateTime.t(), keyword()) :: [map()]
  def index(org_id, resource, %DateTime{} = as_of, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    version_module = Module.concat(resource, Version)

    version_module
    |> published_as_of(as_of, org_id, limit)
    |> Enum.map(fn {id, published_at} ->
      entry(version_module, resource, id, published_at, org_id)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # "Last state transition ≤ as_of per document, keep only publishes" in ONE
  # SQL pass (DISTINCT ON + LIMIT), so the work scales with the number of
  # matching documents (bounded by `limit`), never with total publish history —
  # this backs an unauthenticated endpoint. Raw SQL is deliberate here: Ash has
  # no DISTINCT ON, and version tables are already read as system data.
  # The only interpolation is the TABLE NAME from AshPostgres compile-time
  # metadata — every runtime value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp published_as_of(version_module, as_of, org_id, limit) do
    table = AshPostgres.DataLayer.Info.table(version_module)
    actions = Enum.map(@publish_actions ++ @unpublish_actions, &to_string/1)
    publishes = Enum.map(@publish_actions, &to_string/1)

    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        SELECT version_source_id, version_inserted_at FROM (
          SELECT DISTINCT ON (version_source_id)
            version_source_id, version_action_name, version_inserted_at
          FROM #{table}
          WHERE version_inserted_at <= $1
            AND version_action_name = ANY($2)
            AND ($4::uuid IS NULL OR org_id = $4)
          ORDER BY version_source_id, version_inserted_at DESC, id DESC
        ) latest
        WHERE version_action_name = ANY($3)
        ORDER BY version_inserted_at DESC
        LIMIT $5
        """,
        [DateTime.to_naive(as_of), actions, publishes, org_uuid(org_id), limit]
      )

    Enum.map(rows, fn [source_id, published_at] ->
      {Ecto.UUID.cast!(source_id), DateTime.from_naive!(published_at, "Etc/UTC")}
    end)
  end

  defp org_uuid(nil), do: nil
  defp org_uuid(org_id), do: Ecto.UUID.dump!(org_id)

  # Index fields as of the effective publish — one slim query folding only the
  # versions that touched title/slug (never the full block-tree payloads).
  # `nil` when no slug is reconstructible (history predating version tracking)
  # or when the document row is GONE (hard purge — deliberately erased content
  # must not be re-exposed by the historical index).
  defp entry(version_module, resource, id, published_at, org_id) do
    with true <- still_exists?(resource, id, org_id),
         %{"slug" => slug} = state when is_binary(slug) <-
           title_slug_at(version_module, id, published_at) do
      %{id: id, slug: slug, title: state["title"], published_at: published_at}
    else
      _ -> nil
    end
  end

  # The row still exists in ANY workflow state (archived/trashed rows do; hard
  # purges don't). Raw existence probe — reads across archival state.
  # sobelow_skip ["SQL.Query"]
  defp still_exists?(resource, id, org_id) do
    table = AshPostgres.DataLayer.Info.table(resource)

    %{rows: [[exists]]} =
      KilnCMS.Repo.query!(
        "SELECT EXISTS(SELECT 1 FROM #{table} WHERE id = $1 AND ($2::uuid IS NULL OR org_id = $2))",
        [Ecto.UUID.dump!(id), org_uuid(org_id)]
      )

    exists
  end

  # Fold title/slug through history WITHOUT loading block trees: only versions
  # whose changes touched either key, last value wins.
  # sobelow_skip ["SQL.Query"]
  defp title_slug_at(version_module, id, up_to) do
    table = AshPostgres.DataLayer.Info.table(version_module)

    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        SELECT changes->>'title', changes->>'slug'
        FROM #{table}
        WHERE version_source_id = $1
          AND version_inserted_at <= $2
          AND changes ?| array['title', 'slug']
        ORDER BY version_inserted_at ASC, id ASC
        """,
        [Ecto.UUID.dump!(id), DateTime.to_naive(up_to)]
      )

    Enum.reduce(rows, %{}, fn [title, slug], acc ->
      acc
      |> then(&if(title, do: Map.put(&1, "title", title), else: &1))
      |> then(&if(slug, do: Map.put(&1, "slug", slug), else: &1))
    end)
  end

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
