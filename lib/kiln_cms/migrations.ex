defmodule KilnCMS.Migrations do
  @moduledoc """
  Migration helpers for tables backing `KilnCMS.CMS.Content` resources.

  Every content type's `:search` action filters on a **trigger-maintained
  `search_vector` column** — deliberately not an Ash attribute, so the
  database keeps it correct regardless of how rows are written (see
  `20260623213400_add_locale_weighted_search`). That also means
  `mix ash.codegen` cannot create it: the core migrations cover the core
  tables (`pages`/`posts`/`entries`), and **every new content type's table
  needs its own** — without it, the type's `/search` route raises
  `undefined_column`.

  After the table exists (i.e. in a migration *after* the `ash.codegen` one
  that creates it), add:

      defmodule KilnCMS.Repo.Migrations.AddProductsSearchVector do
        use Ecto.Migration

        import KilnCMS.Migrations

        def up, do: add_search_vector("products")
        def down, do: drop_search_vector("products")
      end

  The table name is the resource's `:table` option — by default `"\#{type}s"`,
  which is **not** always the `:plural` used in routes and interfaces (e.g. a
  resource with `plural: "clinical_evidence"` still lives in table
  `clinical_evidences` unless `:table` was overridden).
  """

  import Ecto.Migration

  @doc """
  Adds the trigger-maintained, locale-weighted `search_vector` column to
  `table`, with its GIN index, and backfills existing rows.

  Mirrors what `20260623213400_add_locale_weighted_search` does for the core
  tables, reusing the shared `kiln_search_vector_refresh()` trigger function
  and `kiln_regconfig(locale)` helper that migration created (title weighted
  `A`, `search_text` weighted `B`, stemmed per the row's locale). The table
  must carry `title`, `search_text`, and `locale` columns — every table built
  by `KilnCMS.CMS.Content` does.

  Everything is guarded (`IF NOT EXISTS`, backfill only where the vector is
  `NULL`), so re-running — or a future core migration covering the same
  table — is a no-op. The backfill is explicit because the trigger only
  fires on insert/update: a deployment that already imported rows would
  otherwise never match them.
  """
  def add_search_vector(table) when is_binary(table) do
    table = validate_table!(table)

    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS search_vector tsvector")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = '#{table}_search_vector_trg'
          AND tgrelid = '#{table}'::regclass
      ) THEN
        CREATE TRIGGER #{table}_search_vector_trg
          BEFORE INSERT OR UPDATE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION kiln_search_vector_refresh();
      END IF;
    END $$
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS #{table}_search_vector_gin ON #{table} USING gin (search_vector)"
    )

    execute("""
    UPDATE #{table} SET search_vector =
      setweight(to_tsvector(kiln_regconfig(locale), coalesce(title, '')), 'A') ||
      setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_text, '')), 'B')
    WHERE search_vector IS NULL
    """)
  end

  @doc """
  Reverts `add_search_vector/1`: drops the trigger, index, and column.

  Leaves the shared `kiln_search_vector_refresh()` / `kiln_regconfig()`
  functions in place — they belong to the core migration and other tables
  still use them.
  """
  def drop_search_vector(table) when is_binary(table) do
    table = validate_table!(table)

    execute("DROP TRIGGER IF EXISTS #{table}_search_vector_trg ON #{table}")
    execute("DROP INDEX IF EXISTS #{table}_search_vector_gin")
    execute("ALTER TABLE #{table} DROP COLUMN IF EXISTS search_vector")
  end

  # The table name is interpolated into DDL, so hold it to identifier rules
  # rather than trusting the caller's string.
  defp validate_table!(table) do
    if table =~ ~r/\A[a-z_][a-z0-9_]*\z/ do
      table
    else
      raise ArgumentError,
            "expected a plain (unquoted) Postgres identifier as the table name, got: #{inspect(table)}"
    end
  end
end
