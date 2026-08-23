defmodule KilnCMS.Search.SchemaCheck do
  @moduledoc """
  Holds the database to what every content type's `:search` action assumes: a
  trigger-maintained `search_vector` column, its refresh trigger, and its GIN
  index, on every table backing a `KilnCMS.CMS.Content` resource.

  That column is deliberately not an Ash attribute — the database keeps it
  correct however a row is written — which also means `mix ash.codegen` cannot
  create it. The core migrations cover `pages`/`posts`/`entries`, and every
  content type added after them needs its own one-line migration
  (`KilnCMS.Migrations.add_search_vector/1`). Forget it and the type's keyword
  leg raises `undefined_column` on every query (#295); before that failure was
  contained, one forgotten migration took the whole site's search down with it.

  Nothing about a missing column is visible in the resource, the domain, or the
  generated migrations — the only place it shows up is a query, at runtime, in
  production. So it gets a check that runs against a migrated database:

      mix kiln.search.check

  `report/0` is the same answer as data, for a test to assert on (the suite
  runs against a migrated database too, which is where this trap gets caught
  before a deploy rather than after).
  """

  alias KilnCMS.Repo

  @typedoc """
  What one content table is missing. `:table` means the table itself is absent
  — migrations have not run — and the rest are not reported for it.
  """
  @type gap :: %{
          resource: module(),
          table: String.t(),
          missing: [:table | :column | :trigger | :index]
        }

  @doc """
  Every content table missing part of its search-vector setup, in resource
  order. `[]` when the database is complete — the state a deployable install
  is in.
  """
  @spec report() :: [gap()]
  def report do
    for resource <- KilnCMS.Search.content_resources(),
        table = table(resource),
        missing = inspect_table(table),
        missing != [],
        do: %{resource: resource, table: table, missing: missing}
  end

  @doc """
  What `table` is missing of the column / trigger / index trio, `[]` when it
  has all three.

  Takes a table name rather than a resource so a test can point it at a table
  it built itself, in the shapes that matter (no column, column but no trigger,
  everything) — the parts of a checker that would otherwise only ever be
  exercised by the passing case.
  """
  @spec inspect_table(String.t()) :: [:table | :column | :trigger | :index]
  def inspect_table(table) when is_binary(table) do
    # The table name is a bound parameter throughout, never interpolated —
    # `add_search_vector/1` derives both object names from it, so `$1` plus the
    # suffix is the same string it built.
    if exists?("SELECT to_regclass($1) IS NOT NULL", [table]) do
      [
        column:
          "SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass($1) " <>
            "AND attname = 'search_vector' AND NOT attisdropped",
        trigger:
          "SELECT 1 FROM pg_trigger WHERE tgrelid = to_regclass($1) " <>
            "AND tgname = $1 || '_search_vector_trg' AND NOT tgisinternal",
        index:
          "SELECT 1 FROM pg_class i JOIN pg_index ix ON ix.indexrelid = i.oid " <>
            "WHERE ix.indrelid = to_regclass($1) AND i.relname = $1 || '_search_vector_gin'"
      ]
      |> Enum.reject(fn {_part, sql} -> exists?(sql, [table]) end)
      |> Enum.map(&elem(&1, 0))
    else
      [:table]
    end
  end

  @doc """
  The migration that closes `gap`, ready to paste into
  `priv/repo/migrations/`.

  The helper is idempotent (`IF NOT EXISTS` throughout, backfill only where the
  vector is `NULL`), so this is also the right answer for a table that is only
  missing its index.
  """
  @spec migration(gap()) :: String.t()
  def migration(%{table: table}) do
    """
    defmodule KilnCMS.Repo.Migrations.Add#{Macro.camelize(table)}SearchVector do
      use Ecto.Migration

      import KilnCMS.Migrations

      def up, do: add_search_vector("#{table}")
      def down, do: drop_search_vector("#{table}")
    end
    """
  end

  # `nil` for a resource on another data layer (a plugin-registered type need
  # not be Postgres-backed); those are simply not this check's business.
  defp table(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end

  # `sobelow_skip`: every statement above is a literal in this module — the
  # table name is bound as `$1`, including for the two derived object names
  # (`$1 || '_search_vector_trg'`). Sobelow flags the shape (`Repo.query!` with
  # a variable) rather than the strings, which carry nothing from a request.
  # sobelow_skip ["SQL.Query"]
  defp exists?(sql, params) do
    # `to_regclass(...) IS NOT NULL` answers with a boolean row; the catalog
    # probes answer with a row or no rows at all. A `[[false]]` is the one shape
    # that must not read as "present".
    case Repo.query!(sql, params).rows do
      [[false] | _] -> false
      [_row | _] -> true
      [] -> false
    end
  end
end
