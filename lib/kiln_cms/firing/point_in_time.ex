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

  Both the single-document read and the collection index resolve the **last
  state transition** at or before the requested moment, so a document that had
  been withdrawn then is reported as withdrawn rather than serving the publish
  that preceded the withdrawal.

  Scope: lookup is by a document's id (the caller resolves it from the
  *current* record), so content that has since been removed isn't reachable
  that way — the collection index is the discovery path. Id-addressable
  history is a later phase.
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
  @state_actions @publish_actions ++ @unpublish_actions

  @doc """
  The **collection view as of a date** (#338 phase 2): every document of
  `resource` that was published at `as_of`, as lightweight index entries

      %{id, slug, title, published_at}

  reconstructed from version history (title/slug as they were at that
  document's last publish ≤ `as_of`). A document unpublished before `as_of`
  is excluded — an index that listed since-removed content would
  misrepresent the site as it stood. Bounded by `limit` (newest publishes
  first).

  `:type_definition_id` scopes the read to one **dynamic** type (D17). Every
  dynamic type shares the `KilnCMS.CMS.Entry` table, so without it an index
  for one type would list every other type's documents too.
  """
  @spec index(Ash.UUID.t(), module(), DateTime.t(), keyword()) :: [map()]
  def index(org_id, resource, %DateTime{} = as_of, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    version_module = Module.concat(resource, Version)

    version_module
    |> published_as_of(resource, as_of, org_id, limit, opts[:type_definition_id])
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
  defp published_as_of(version_module, resource, as_of, org_id, limit, definition_id) do
    table = AshPostgres.DataLayer.Info.table(version_module)
    source_table = AshPostgres.DataLayer.Info.table(resource)
    actions = Enum.map(@state_actions, &to_string/1)
    publishes = Enum.map(@publish_actions, &to_string/1)

    params = [DateTime.to_naive(as_of), actions, publishes, dump_uuid(org_id), limit]

    # The dynamic-type scope reads the type off the SOURCE row, not the version
    # `changes` map: `type_definition_id` only appears in the create version's
    # diff, so a publish/unpublish row carries no type at all. The source row is
    # the authority anyway — a document cannot change type.
    #
    # The clause is omitted entirely for compiled types rather than guarded by a
    # nil bind: Postgres validates column references at parse time, so
    # `$6 IS NULL OR s.type_definition_id = $6` still fails on a `posts` table
    # that has no such column.
    {type_scope, params} =
      if definition_id do
        {"""
           AND EXISTS (
             SELECT 1 FROM #{source_table} s
             WHERE s.id = v.version_source_id AND s.type_definition_id = $6
           )
         """, params ++ [dump_uuid(definition_id)]}
      else
        {"", params}
      end

    %{rows: rows} =
      KilnCMS.Repo.query!(
        """
        SELECT version_source_id, version_inserted_at FROM (
          SELECT DISTINCT ON (version_source_id)
            version_source_id, version_action_name, version_inserted_at
          FROM #{table} v
          WHERE version_inserted_at <= $1
            AND version_action_name = ANY($2)
            AND ($4::uuid IS NULL OR org_id = $4)
            #{type_scope}
          ORDER BY version_source_id, version_inserted_at DESC, id DESC
        ) latest
        WHERE version_action_name = ANY($3)
        ORDER BY version_inserted_at DESC
        LIMIT $5
        """,
        params
      )

    Enum.map(rows, fn [source_id, published_at] ->
      {Ecto.UUID.cast!(source_id), DateTime.from_naive!(published_at, "Etc/UTC")}
    end)
  end

  # Bind a UUID as a query parameter, preserving nil — the SQL reads a nil bind
  # as "no filter on this axis".
  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)

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
        [Ecto.UUID.dump!(id), dump_uuid(org_id)]
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
  `as_of`, plus the effective publish time.

    * `{:error, :not_published}` — nothing had been published by then.
    * `{:error, :withdrawn}` — it *had* been published, but was unpublished or
      archived before `as_of` and not republished by then. Serving the earlier
      publish here would assert that content was live at a moment it had
      already been taken down — the exact claim this endpoint exists to make
      truthfully.
  """
  @spec read(Ash.UUID.t(), module(), Ash.UUID.t(), atom(), DateTime.t()) ::
          {:ok, map(), DateTime.t()} | {:error, :not_published | :withdrawn}
  def read(org_id, resource, id, surface, %DateTime{} = as_of) do
    version_module = Module.concat(resource, Version)

    # Version rows inherit the source's tenant (epic #336), so the history reads
    # are scoped to this org; the rebuilt document is re-stamped with `org_id` so
    # the in-memory re-fire stays in the right tenant.
    case last_transition(version_module, id, as_of, org_id) do
      {:ok, published_at} ->
        {:ok, artifacts} =
          version_module
          |> replay(id, published_at, org_id)
          |> build_document(resource, id, org_id)
          # `:as_stored` — the replayed `custom_fields` are what this document
          # actually carried at `as_of`. Recomputing them would derive from
          # today's formulas, and projecting onto today's field definitions
          # would add fields defined since and drop fields since deleted, making
          # the historical artifact assert values that were never live then.
          # `fragments: as_of` for the same reason (#917). `Fragments.expand/3`
          # otherwise reads the target's *current* published blocks, so a
          # historical read returned the fragment as edited today — or an empty
          # `blocks` array where the content was, if the target has since been
          # unpublished or gated. Both are silent wrong answers on the one
          # endpoint whose entire promise is "what did this say on…".
          |> Engine.fire(mode: :preview, custom_fields: :as_stored, fragments: as_of)

        {:ok, Map.fetch!(artifacts, surface), published_at}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The most recent publish/unpublish transition at or before `as_of`. A publish
  # bounds the replay; an unpublish means the document was dark at that moment.
  # Mirrors the `DISTINCT ON` pass behind `index/4` — the two views must agree
  # on what "published then" means, or a document could be absent from the
  # historical index while its own snapshot still served content.
  defp last_transition(version_module, id, as_of, org_id) do
    version_module
    |> Ash.Query.filter(
      version_source_id == ^id and version_inserted_at <= ^as_of and
        version_action_name in ^@state_actions
    )
    # id tiebreaks a publish and an unpublish sharing a timestamp, as in index/4.
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false, tenant: org_id)
    |> case do
      {:ok, [%{version_action_name: action} = version]} when action in @publish_actions ->
        {:ok, version.version_inserted_at}

      {:ok, [_unpublished]} ->
        {:error, :withdrawn}

      _none ->
        {:error, :not_published}
    end
  end

  @doc """
  The attribute state `id` carried at `as_of`, if it was published then (#917).

  The fragment-expansion counterpart of `read/5`: a point-in-time artifact has
  to inline what the target said *then*, and this is the primitive
  `KilnCMS.CMS.Fragments` calls to get it.

  Returns the whole replayed state, string-keyed, **not just the blocks** — the
  caller has to re-apply the visibility rules against the values that were live
  at `as_of` (`"audience"`, and `"type_definition_id"` for a dynamic type), and
  it can only do that if it can see them. Handing back blocks alone is what made
  the first cut of this leak a gated fragment into a public artifact.

  `:absent` covers every reason a target has no historical body — never
  published, withdrawn before `as_of`, hard-purged since, or no version rows at
  all — which expansion treats exactly as it treats an unpublished target
  today: it expands to nothing.

  Deliberately reuses `last_transition/4` and `still_exists?/3`, so "published
  then" and "not erased" mean the same thing here, in `read/5` and in
  `index/4`. A fragment visible in one and not the others would be the same
  class of disagreement those two guard against.
  """
  @spec snapshot_state(Ash.UUID.t(), module(), Ash.UUID.t(), DateTime.t()) ::
          {:ok, map()} | :absent
  def snapshot_state(org_id, resource, id, %DateTime{} = as_of) do
    version_module = Module.concat(resource, Version)

    with true <- still_exists?(resource, id, org_id),
         {:ok, published_at} <- last_transition(version_module, id, as_of, org_id) do
      {:ok, replay(version_module, id, published_at, org_id)}
    else
      _absent -> :absent
    end
  rescue
    # A target whose version table can't be read is a miss, not a 500 on a
    # governance page — the same posture `read_target_live/4` takes.
    _error -> :absent
  end

  # Reconstruct the full attribute state at `up_to` by merging every version's
  # `changes` in chronological order (`:changes_only` tracking).
  #
  # `KilnCMS.CMS.VersionSnapshot` owns that fold, and this used to carry its own
  # copy — sorted on `version_inserted_at` alone, with no tiebreak (#692). Two
  # versions written in one transaction share an instant, so their merge order
  # was whatever Postgres happened to return, and this endpoint could reconstruct
  # a *different* document than restore and version-compare did for the same
  # moment. On the one API whose whole promise is "what did this say at T", two
  # answers is the same as none.
  #
  # The file already knew timestamps aren't unique: `last_transition/4` tiebreaks
  # on `id`, and `title_slug_at/3`'s raw SQL orders `version_inserted_at ASC, id
  # ASC`. Only the Elixir fold missed it.
  defp replay(version_module, id, up_to, org_id) do
    KilnCMS.CMS.VersionSnapshot.at_time(version_module, id, up_to,
      authorize?: false,
      tenant: org_id
    )
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
    resource
    |> struct(attrs |> Map.put(:id, id) |> Map.put(:org_id, org_id))
    |> as_stored_seo()
  end

  # The replayed document's own SEO fields, stamped onto the `effective_seo_*`
  # calculations the fired `:json_ld` reads (#1102).
  #
  # Same rule as `custom_fields: :as_stored` and `fragments: as_of` above, and
  # the same failure without it: `KilnCMS.Seo.Patterns.effective/3` falls back to
  # resolving the type's #805 pattern from the **live** registry, so a historical
  # artifact would carry a description assembled from a pattern written this week
  # — on the one endpoint whose promise is what the document said then. A
  # calculation that is already loaded is returned verbatim, so pre-setting it to
  # the stored value is how "as stored" is expressed here.
  defp as_stored_seo(document) do
    Enum.reduce([:seo_title, :seo_description], document, fn field, acc ->
      calculation = KilnCMS.Seo.Patterns.calculation_name(field)

      if Map.has_key?(acc, calculation),
        do: Map.put(acc, calculation, Map.get(acc, field)),
        else: acc
    end)
  end
end
