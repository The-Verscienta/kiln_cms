defmodule Kiln.CoreAgnosticTest do
  @moduledoc """
  Guards the invariant that the reusable core ships **no** downstream project's
  schema (see the `:ash_domains` / `:content_domains` notes in `config/config.exs`).

  Two regressions motivated this, and neither was visible to the rest of the
  suite — the core was internally self-consistent, creating the leaked tables
  *and* indexing them, so migrations ran and every test passed:

    * **#288** extracted the Verscienta subproject downstream but left its two
      migrations and twelve resource-snapshot directories behind, so a clean
      build for any *other* project still created empty `herbs`/`formulas`/…
      tables.
    * **#290** then found two core hot-path index migrations still naming those
      tables in their `@content_tables` lists. That only surfaced once the
      creating migration was gone (`relation "herbs" does not exist`) — while
      the leak was intact, CI stayed green.

  A table is *owned* when some resource in a registered `:ash_domains` domain
  maps to it: that covers AshPaperTrail version resources (`pages_versions`)
  and the `through` resources behind `many_to_many` relationships.

  This holds unchanged in a downstream overlay tree: an overlay registers its
  own domain *and* ships the matching `priv/` migrations and snapshots, so its
  tables are owned there and absent here.
  """
  use KilnCMS.DataCase, async: true

  @snapshots_path "priv/resource_snapshots/repo"

  # Tables with no Ash resource behind them: core infrastructure, not content
  # schema. `oban_*` (oban_jobs, oban_peers) comes from `Oban.Migration.up/0`.
  @infra_tables ~w(schema_migrations collab_doc_states)

  test "every migrated table is owned by a resource in a registered domain" do
    owned = owned_tables()

    leaked =
      database_tables()
      |> Enum.reject(&(MapSet.member?(owned, &1) or infra?(&1)))
      |> Enum.sort()

    assert leaked == [], """
    The core database has #{length(leaked)} table(s) that no resource in
    `:ash_domains` owns:

        #{Enum.join(leaked, "\n    ")}

    Either they belong to a downstream project (move their migration and
    resource snapshots into that project's overlay `priv/`, and drop the table
    names from any core migration that enumerates them, e.g. the
    `@content_tables` lists in the hot-path index migrations), or they are core
    infrastructure with no Ash resource, in which case add them to
    `@infra_tables` in this test with a note saying why.
    """
  end

  test "every resource snapshot maps to a resource in a registered domain" do
    owned = owned_tables()

    orphans =
      snapshot_tables()
      |> Enum.reject(&MapSet.member?(owned, &1))
      |> Enum.sort()

    assert orphans == [], """
    #{@snapshots_path} has #{length(orphans)} snapshot director(ies) with no
    backing resource in `:ash_domains`:

        #{Enum.join(orphans, "\n    ")}

    A snapshot outliving its resource means the resource moved downstream (or
    was deleted) without its generated artifacts. Move the snapshot directory
    into the owning project's overlay `priv/resource_snapshots/repo/`.
    """
  end

  defp infra?(table), do: table in @infra_tables or String.starts_with?(table, "oban_")

  defp database_tables do
    %Postgrex.Result{rows: rows} =
      KilnCMS.Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      """)

    List.flatten(rows)
  end

  defp snapshot_tables do
    @snapshots_path
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@snapshots_path, &1)))
  end

  # Every table reachable from a registered domain: the resources themselves
  # plus the join resources their `many_to_many` relationships route through.
  defp owned_tables do
    :kiln_cms
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.flat_map(&[&1 | join_resources(&1)])
    |> Enum.uniq()
    |> Enum.map(&postgres_table/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp join_resources(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :many_to_many))
    |> Enum.map(& &1.through)
  end

  defp postgres_table(resource) do
    if Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer do
      AshPostgres.DataLayer.Info.table(resource)
    end
  end
end
