defmodule KilnCMS.Test.TypeCache do
  @moduledoc """
  Loads every type the migrations created into Postgrex's type cache before
  the first test runs, so none is loaded for the first time while async tests
  race for it (#1796).

  ## Why

  Postgrex caches type information per `{types module, host, port, database}`
  in one ETS table, shared by every connection in the pool. The table is
  filled once, by the first connection's bootstrap query. A type created
  *after* that is loaded lazily, the first time a query uses it.

  On a fresh database, the `mix test` alias runs `ash.setup` in the same VM as
  the tests: the repo connects (bootstrapping the type table from an empty
  database), the migrations create the extension and Oban types, and the test
  run then reuses that table. So `citext`, `vector`, `halfvec`, `sparsevec`,
  `gtrgm` and their arrays, and before 2026-10-01 Oban's `oban_job_state` too,
  were first loaded by whichever test touched them, while the other async
  tests were starting up.

  Postgrex publishes a lazily loaded batch in two passes
  (`Postgrex.Types.associate_type_infos/2`): it inserts every row with no
  codec yet, then resolves each one. A connection that describes a query
  using one of those types between the two passes reads the unresolved row
  and fails with ``type `_oban_job_state` can not be handled by the types
  module KilnCMS.PostgrexTypes``. That is the CI failure in #1796: a publish's
  unique Oban job insert, three seconds into a fresh shard. It is transient,
  because the row is resolved a moment later, so a rerun passes.

  Locally, the test database is usually already migrated, so the bootstrap
  sees every type and the race cannot happen. That is why this only showed
  up in CI.

  ## The fix

  `warm!/1` runs one query that selects a `NULL` of every such type, from the
  single process running `test_helper.exs`, before ExUnit starts any test. The
  types load in one batch with nobody else querying, and no test can then be
  the first to touch one. `type_cache_test.exs` checks that none is left out.
  """

  @doc """
  Every type a query can name: no row types of tables (the bootstrap skips
  those too), no pseudo-types, none from Postgres's own schemas (the bootstrap
  always has those), and none without a binary send function, which Postgrex
  cannot handle whenever it is loaded (`pg_trgm`'s internal index type
  `gtrgm`, and arrays of such a type).
  """
  def types_sql do
    """
    SELECT t.oid::int, format('%I.%I', n.nspname, t.typname)
    FROM pg_catalog.pg_type AS t
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    WHERE t.typrelid = 0
      AND t.typisdefined
      AND t.typtype <> 'p'
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg\\_%'
      AND t.typsend::oid <> 0
      AND (t.typelem = 0 OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_type AS e
        WHERE e.oid = t.typelem AND (e.typrelid <> 0 OR e.typsend::oid = 0)
      ))
    ORDER BY t.oid
    """
  end

  @doc "Loads every type `types_sql/0` lists into `repo`'s type cache, in one query."
  def warm!(repo) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fn ->
      %{rows: rows} = repo.query!(types_sql())
      load(repo, rows)
    end)
  end

  defp load(_repo, []), do: :ok

  defp load(repo, rows) do
    repo.query!("SELECT " <> Enum.map_join(rows, ", ", &null_of/1))
    :ok
  end

  defp null_of([_oid, name]), do: "NULL::" <> name
end
