defmodule KilnCMS.CMS.ContentLinks.Backfill do
  @moduledoc """
  Writes the reference edges (#1594) for `:reference` custom field values
  stored before 1.1, and deletes edges no stored value implies any more.

  Run by the `BackfillReferenceLinks` data migration on upgrade, by
  `mix kiln.links.backfill`, and in a release by
  `bin/kiln_cms eval 'KilnCMS.Release.backfill_reference_links()'`.
  **Idempotent**: an edge that already exists is left alone (`ON CONFLICT DO
  NOTHING` on the link's unique identity), so a second run inserts nothing and
  a run after a partial one completes it.

  ## Why SQL, not Ash

  A data migration runs against the schema *as of that migration*, and a
  later release's resources may select columns that do not exist yet when an
  install upgrades several releases at once. These statements name only the
  columns they need — the content tables' `id`, `org_id`, `custom_fields` (and
  `type_definition_id` on `entries`), and the field and type definitions' keys
  — none of which a minor release may drop. One `INSERT … SELECT` per content
  table, so a large table costs one statement, not one round trip per row.

  It reads the **live** `custom_fields` column only. A published record's
  working copy (`working_fields`) is not a link until it is published, exactly
  as `KilnCMS.CMS.Changes.SyncReferenceLinks` treats it. Trashed records are
  included: their edges are kept for a restore, as the write path keeps them.
  """

  require Logger

  alias KilnCMS.CMS.ContentTypes

  @typedoc "Edges inserted and deleted."
  @type result :: %{inserted: non_neg_integer(), deleted: non_neg_integer()}

  # A uuid, as text. `->> 'id'` is whatever a writer stored, and casting a
  # non-uuid to `::uuid` would abort the whole statement.
  @uuid ~S"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  @doc "Insert the missing edges, then delete the stale ones."
  @spec run(Ecto.Repo.t()) :: result()
  def run(repo \\ KilnCMS.Repo) do
    inserted = Enum.reduce(sources(), 0, &(&2 + insert(repo, &1)))
    deleted = prune(repo)

    if inserted + deleted > 0 do
      Logger.info("reference links: #{inserted} written, #{deleted} removed")
    end

    %{inserted: inserted, deleted: deleted}
  end

  # Every table holding content, with how a row names its type and finds its
  # field definitions. Compiled types join their definitions on
  # `content_type`; the shared `entries` table (D17) joins on the row's own
  # `type_definition_id`, and its type name is that definition's name.
  defp sources do
    compiled =
      for %{type: type, resource: resource} <- ContentTypes.all(), not is_nil(resource) do
        {:compiled, table(resource), to_string(type)}
      end

    Enum.uniq(compiled) ++ [{:dynamic, table(KilnCMS.CMS.Entry)}]
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  # sobelow_skip ["SQL.Query"]
  defp insert(repo, {:compiled, table, type}) do
    """
    INSERT INTO content_links
      (id, org_id, source_id, target_id, kind, position, metadata, field, source_type, target_type)
    SELECT gen_random_uuid(), c.org_id, c.id, (c.custom_fields -> fd.name ->> 'id')::uuid,
           'reference', 0, '{}'::jsonb, fd.name, $1,
           COALESCE(NULLIF(c.custom_fields -> fd.name ->> 'type', ''), fd.target_type)
      FROM #{table} c
      JOIN field_definitions fd
        ON fd.org_id = c.org_id
       AND fd.content_type = $1
       AND fd.type_definition_id IS NULL
       AND fd.field_type = 'reference'
     WHERE jsonb_typeof(c.custom_fields -> fd.name) = 'object'
       AND (c.custom_fields -> fd.name ->> 'id') ~ $2
    ON CONFLICT DO NOTHING
    """
    |> execute(repo, [type, @uuid])
  end

  # sobelow_skip ["SQL.Query"]
  defp insert(repo, {:dynamic, table}) do
    """
    INSERT INTO content_links
      (id, org_id, source_id, target_id, kind, position, metadata, field, source_type, target_type)
    SELECT gen_random_uuid(), c.org_id, c.id, (c.custom_fields -> fd.name ->> 'id')::uuid,
           'reference', 0, '{}'::jsonb, fd.name, td.name,
           COALESCE(NULLIF(c.custom_fields -> fd.name ->> 'type', ''), fd.target_type)
      FROM #{table} c
      JOIN type_definitions td ON td.id = c.type_definition_id
      JOIN field_definitions fd
        ON fd.type_definition_id = c.type_definition_id
       AND fd.field_type = 'reference'
     WHERE jsonb_typeof(c.custom_fields -> fd.name) = 'object'
       AND (c.custom_fields -> fd.name ->> 'id') ~ $1
    ON CONFLICT DO NOTHING
    """
    |> execute(repo, [@uuid])
  end

  # An edge whose source no longer stores that target under that field: the
  # value was cleared or re-pointed by something that bypassed the write path,
  # or the source was purged. One statement across every content table.
  # sobelow_skip ["SQL.Query"]
  defp prune(repo) do
    tables =
      sources()
      |> Enum.map(fn
        {:compiled, table, _type} -> table
        {:dynamic, table} -> table
      end)
      |> Enum.uniq()

    holders =
      Enum.map_join(tables, "\n        UNION ALL\n", fn table ->
        """
                SELECT 1 FROM #{table} c
                 WHERE c.id = cl.source_id
                   AND c.custom_fields -> cl.field ->> 'id' = cl.target_id::text
        """
      end)

    """
    DELETE FROM content_links cl
     WHERE cl.kind = 'reference'
       AND NOT EXISTS (
    #{holders}
       )
    """
    |> execute(repo, [])
  end

  defp execute(sql, repo, params) do
    %{num_rows: rows} = repo.query!(sql, params, timeout: :infinity)
    rows
  end
end
