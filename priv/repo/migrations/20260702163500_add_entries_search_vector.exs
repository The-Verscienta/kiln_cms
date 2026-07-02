defmodule KilnCMS.Repo.Migrations.AddEntriesSearchVector do
  @moduledoc """
  Locale-weighted full-text search for the generic entry table (dynamic content
  types — D17), mirroring `add_locale_weighted_search`: the same shared
  `kiln_search_vector_refresh()` trigger function maintains a `search_vector`
  column (title = A, search_text = B, stemmed per the row's locale). No
  backfill — the table is created empty in `add_entries`.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE entries ADD COLUMN search_vector tsvector")

    execute("""
    CREATE TRIGGER entries_search_vector_trg
      BEFORE INSERT OR UPDATE ON entries
      FOR EACH ROW EXECUTE FUNCTION kiln_search_vector_refresh()
    """)

    execute("CREATE INDEX entries_search_vector_gin ON entries USING gin (search_vector)")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS entries_search_vector_trg ON entries")
    execute("DROP INDEX IF EXISTS entries_search_vector_gin")
    execute("ALTER TABLE entries DROP COLUMN IF EXISTS search_vector")
  end
end
