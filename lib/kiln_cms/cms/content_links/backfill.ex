defmodule KilnCMS.CMS.ContentLinks.Backfill do
  @moduledoc """
  Rebuilds the top-level reference edges (#1594) from the stored
  `:reference` custom field values: writes the missing ones, realigns the
  position and link values of the ones that drifted, and deletes the edges no
  stored value holds any more.

  Run by the `BackfillReferenceLinks` data migration on upgrade, by
  `mix kiln.links.backfill`, and in a release by
  `bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'`.
  **Idempotent**: an edge that already exists is left alone (`ON CONFLICT DO
  NOTHING` on the link's unique identity), so a second run writes, realigns
  and removes nothing, and a run after a partial one completes it.

  ## What it writes

  The edges `KilnCMS.CMS.ContentLinks.desired/2` implies for a top-level
  `:reference` field, whatever shape the value has:

    * an object (a single reference) is one edge at position 0;
    * a list (`multiple: true`, #2289 R1) is one edge per element, at the
      element's index in the stored list, so `[a, "junk", b]` gives `a` at 0
      and `b` at 2;
    * an element counts only when its `"id"` is a uuid string; a bare string,
      `null`, `[]` or a non-uuid id implies nothing;
    * a target named twice in one list is one edge, at its **last** place, as
      `desired/2` keeps it;
    * `metadata` is the element's `"link"` when that is an object, else `{}`;
    * uuids compare case-insensitively: an id stored in upper case is the
      edge the `uuid` column holds in lower case, not a new one.

  The shape is read from the value (`jsonb_typeof`), never from the field
  definition's `multiple` flag, so a value stored before a single ↔ list flip
  is still read as what it is.

  Realign rewrites `position` and `metadata` of an existing edge that
  disagrees with the stored value.

  A save that lands while a run is in progress can race it in two ways, each
  lasting until that record's next changing save:

    * realign can set the edge back to the position or link values the value
      held when the run read it;
    * a save that removes a target can be crossed by the insert, which writes
      back the edge the save just deleted. That stale edge holds a target
      whose field is `on_target_delete: :restrict`.

  Run it in a quiet period.

  ## What it keeps

  The prune errs toward keeping: an edge stays while its source row still
  holds its target's id, as uuid text, under its field, in either shape and
  in any case, whatever the field definitions say. A bug in the prune deletes
  data, so it never joins the definitions and never compares positions. The
  one edge it deletes although the write path would keep it is one for a raw
  16-byte id (see below).

  A reference inside a group row or a flexible item (#2282) has an edge keyed
  by its dotted definition path (`visits.doctor`). The backfill neither writes
  nor realigns those (field names never contain a dot, so the path is never a
  key of `custom_fields`); it keeps them while their source row exists, and a
  record's next changing save reconciles them. They are deleted with a purged
  source like any other edge.

  ## Known differences from the write path

    * `target_type` falls back to the field's `target_type` when a value names
      no `"type"`; the write path also consults `target_types`, a later
      column. Snapshots carry `"type"` anyway, and realign leaves
      `target_type` alone, so the next changing save settles it.
    * Any 16-byte string passes `Ecto.UUID.cast/1` as a raw id, so the write
      path writes an edge for one. This backfill reads only the 36-character
      text form: it writes no such edge, and its prune deletes one, since it
      never matches the text compare; the record's next changing save writes
      it back. Follow-up #3356.
    * It does not check a field's `max_sources` cap.

  ## Why SQL, not Ash

  A data migration runs against the schema *as of that migration*, and a
  later release's resources may select columns that do not exist yet when an
  install upgrades several releases at once. These statements name only the
  columns they need — the content tables' `id`, `org_id`, `custom_fields` (and
  `type_definition_id` on `entries`), the field definitions' `org_id`,
  `content_type`, `type_definition_id`, `name`, `field_type` and
  `target_type`, the type definitions' `id` and `name`, and `content_links` —
  none of which a minor release may drop. Never the definitions' `multiple`,
  `target_types`, `group_of_id`, `flex_of_id` or `link_of_id`: those came
  after the 1.1 data migration that runs this. One statement per content
  table and step, so a large table costs a few statements, not one round trip
  per row.

  It reads the **live** `custom_fields` column only. A published record's
  working copy (`working_fields`) is not a link until it is published, exactly
  as `KilnCMS.CMS.Changes.SyncReferenceLinks` treats it. Trashed records are
  included: their edges are kept for a restore, as the write path keeps them.
  """

  require Logger

  alias KilnCMS.CMS.ContentTypes

  @typedoc "Edges inserted, realigned and deleted."
  @type result :: %{
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          deleted: non_neg_integer()
        }

  # A uuid, as text. `->> 'id'` is whatever a writer stored, and casting a
  # non-uuid to `::uuid` would abort the whole statement.
  @uuid ~S"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  @doc "Insert the missing edges, realign the drifted ones, then delete the stale ones."
  @spec run(Ecto.Repo.t()) :: result()
  def run(repo \\ KilnCMS.Repo) do
    sources = sources()
    inserted = Enum.reduce(sources, 0, &(&2 + execute(insert_sql(&1), repo)))
    updated = Enum.reduce(sources, 0, &(&2 + execute(realign_sql(&1), repo)))
    deleted = execute(prune_sql(sources), repo)

    if inserted + updated + deleted > 0 do
      Logger.info(
        "reference links: #{inserted} written, #{updated} realigned, #{deleted} removed"
      )
    end

    %{inserted: inserted, updated: updated, deleted: deleted}
  end

  @doc false
  # Every statement `run/1` sends, for the guard that keeps them to columns
  # the 1.1 data migration's schema has.
  @spec statements() :: [String.t()]
  def statements do
    sources = sources()

    Enum.map(sources, &(&1 |> insert_sql() |> elem(0))) ++
      Enum.map(sources, &(&1 |> realign_sql() |> elem(0))) ++
      [sources |> prune_sql() |> elem(0)]
  end

  # Every table holding content, with how a row names its type and finds its
  # field definitions. Compiled types join their definitions on
  # `content_type`; the shared `entries` table (D17) joins on the row's own
  # `type_definition_id`, and its type name is that definition's name.
  defp sources do
    # `ContentTypes.all/0` keeps the domain resources that export
    # `__kiln_content_type__/0`, and `function_exported?/3` is false for a
    # module not yet loaded. Under `mix ecto.migrate` nothing has loaded them
    # (code is loaded on first use), so the migration saw no compiled type and
    # backfilled nothing. Load them first.
    for domain <- ContentTypes.content_domains(),
        resource <- Ash.Domain.Info.resources(domain),
        do: Code.ensure_loaded(resource)

    compiled =
      for %{type: type, resource: resource} <- ContentTypes.all(), not is_nil(resource) do
        {:compiled, table(resource), to_string(type)}
      end

    Enum.uniq(compiled) ++ [{:dynamic, table(KilnCMS.CMS.Entry)}]
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  # The edges one table's stored values imply, one row per (source, field,
  # target), as `ContentLinks.desired/2` builds them. `$1` is the uuid
  # pattern; a compiled type's name is `$2`.
  defp desired({:compiled, table, type}) do
    sql =
      desired_select(table, "$2::text", """
        JOIN field_definitions fd
          ON fd.org_id = c.org_id
         AND fd.content_type = $2
         AND fd.type_definition_id IS NULL
         AND fd.field_type = 'reference'
      """)

    {sql, [@uuid, type]}
  end

  defp desired({:dynamic, table}) do
    sql =
      desired_select(table, "td.name", """
        JOIN type_definitions td ON td.id = c.type_definition_id
        JOIN field_definitions fd
          ON fd.type_definition_id = c.type_definition_id
         AND fd.field_type = 'reference'
      """)

    {sql, [@uuid]}
  end

  # `DISTINCT ON … ORDER BY … e.ord DESC` keeps a target's last place in the
  # list, as `Map.new/2` over `desired/2` does. The `::uuid` cast is guarded
  # by its own `CASE`: Postgres does not promise to filter before it projects.
  defp desired_select(table, source_type, joins) do
    """
    SELECT DISTINCT ON (c.id, fd.name, lower(e.v ->> 'id'))
           c.org_id, c.id AS source_id, fd.name AS field,
           CASE WHEN (e.v ->> 'id') ~ $1 THEN (e.v ->> 'id')::uuid END AS target_id,
           (e.ord - 1)::integer AS position,
           CASE WHEN jsonb_typeof(e.v -> 'link') = 'object' THEN e.v -> 'link'
                ELSE '{}'::jsonb END AS metadata,
           #{source_type} AS source_type,
           COALESCE(CASE WHEN jsonb_typeof(e.v -> 'type') = 'string'
                         THEN NULLIF(e.v ->> 'type', '') END,
                    NULLIF(fd.target_type, '')) AS target_type
      FROM #{table} c
    #{joins}
     CROSS JOIN LATERAL (
       SELECT e.v, e.ord FROM #{elements("c.custom_fields -> fd.name")}
        WHERE jsonb_typeof(e.v -> 'id') = 'string' AND (e.v ->> 'id') ~ $1
     ) e
     ORDER BY c.id, fd.name, lower(e.v ->> 'id'), e.ord DESC
    """
  end

  # A stored value as a set of `(v, ord)` rows: a list's elements, an object
  # as a list of one, anything else (null, a string, a number) as none.
  defp elements(value) do
    "jsonb_array_elements(CASE jsonb_typeof(#{value}) WHEN 'array' THEN #{value} " <>
      "WHEN 'object' THEN jsonb_build_array(#{value}) ELSE '[]'::jsonb END) " <>
      "WITH ORDINALITY AS e(v, ord)"
  end

  defp insert_sql(source) do
    {desired, params} = desired(source)

    sql = """
    INSERT INTO content_links
      (id, org_id, source_id, target_id, kind, position, metadata, field, source_type, target_type)
    SELECT gen_random_uuid(), d.org_id, d.source_id, d.target_id, 'reference', d.position,
           d.metadata, d.field, d.source_type, d.target_type
      FROM (#{desired}) d
    ON CONFLICT DO NOTHING
    """

    {sql, params}
  end

  # Not `target_type`: see the moduledoc's known differences.
  defp realign_sql(source) do
    {desired, params} = desired(source)

    sql = """
    UPDATE content_links cl
       SET position = d.position, metadata = d.metadata
      FROM (#{desired}) d
     WHERE cl.kind = 'reference'
       AND cl.org_id = d.org_id
       AND cl.source_id = d.source_id
       AND cl.field = d.field
       AND cl.target_id = d.target_id
       AND (cl.position IS DISTINCT FROM d.position OR cl.metadata IS DISTINCT FROM d.metadata)
    """

    {sql, params}
  end

  # An edge whose source no longer holds that target under that field: the
  # value was cleared or re-pointed by something that bypassed the write path,
  # or the source was purged. One statement across every content table. A
  # nested path (`visits.doctor`) is kept while its source exists; see the
  # moduledoc.
  defp prune_sql(sources) do
    holders =
      sources
      |> Enum.map(fn
        {:compiled, table, _type} -> table
        {:dynamic, table} -> table
      end)
      |> Enum.uniq()
      |> Enum.map_join("\n   UNION ALL\n", fn table ->
        """
           SELECT 1 FROM #{table} c
            WHERE c.id = cl.source_id
              AND (strpos(cl.field, '.') > 0
                   OR EXISTS (SELECT 1 FROM #{elements("c.custom_fields -> cl.field")}
                               WHERE jsonb_typeof(e.v -> 'id') = 'string'
                                 AND lower(e.v ->> 'id') = cl.target_id::text))
        """
      end)

    sql = """
    DELETE FROM content_links cl
     WHERE cl.kind = 'reference'
       AND NOT EXISTS (
    #{holders}
       )
    """

    {sql, []}
  end

  # sobelow_skip ["SQL.Query"]
  defp execute({sql, params}, repo) do
    %{num_rows: rows} = repo.query!(sql, params, timeout: :infinity)
    rows
  end
end
