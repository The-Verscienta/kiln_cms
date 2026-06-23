defmodule KilnCMS.Repo.Migrations.AddLocaleWeightedSearch do
  @moduledoc """
  Locale-aware, weighted full-text search.

  Adds an immutable `kiln_regconfig(locale)` helper mapping a content locale to a
  Postgres text-search config, and a trigger-maintained `search_vector` column on
  `pages`/`posts` built with that config and weighted (title = A, the rest = B).
  Searches stem with the row's own language and rank title hits above body hits.

  `search_vector` is maintained entirely in the database (not an Ash attribute),
  so the trigger keeps it correct regardless of how rows are written.
  """
  use Ecto.Migration

  @tables ["pages", "posts"]

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION kiln_regconfig(loc text) RETURNS regconfig AS $$
      SELECT CASE lower(left(coalesce(loc, ''), 2))
        WHEN 'en' THEN 'english'    WHEN 'fr' THEN 'french'
        WHEN 'de' THEN 'german'     WHEN 'es' THEN 'spanish'
        WHEN 'it' THEN 'italian'    WHEN 'pt' THEN 'portuguese'
        WHEN 'nl' THEN 'dutch'      WHEN 'ru' THEN 'russian'
        WHEN 'sv' THEN 'swedish'    WHEN 'no' THEN 'norwegian'
        WHEN 'da' THEN 'danish'     WHEN 'fi' THEN 'finnish'
        ELSE 'simple'
      END::regconfig
    $$ LANGUAGE sql IMMUTABLE;
    """)

    # One shared trigger function — both tables carry title/search_text/locale.
    execute("""
    CREATE OR REPLACE FUNCTION kiln_search_vector_refresh() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT'
         OR NEW.title       IS DISTINCT FROM OLD.title
         OR NEW.search_text IS DISTINCT FROM OLD.search_text
         OR NEW.locale      IS DISTINCT FROM OLD.locale THEN
        NEW.search_vector :=
          setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.title, '')), 'A') ||
          setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.search_text, '')), 'B');
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql;
    """)

    for table <- @tables do
      execute("ALTER TABLE #{table} ADD COLUMN search_vector tsvector")

      execute("""
      CREATE TRIGGER #{table}_search_vector_trg
        BEFORE INSERT OR UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION kiln_search_vector_refresh()
      """)

      execute("CREATE INDEX #{table}_search_vector_gin ON #{table} USING gin (search_vector)")

      # Backfill existing rows (the trigger only fires on future writes).
      execute("""
      UPDATE #{table} SET search_vector =
        setweight(to_tsvector(kiln_regconfig(locale), coalesce(title, '')), 'A') ||
        setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_text, '')), 'B')
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("DROP TRIGGER IF EXISTS #{table}_search_vector_trg ON #{table}")
      execute("DROP INDEX IF EXISTS #{table}_search_vector_gin")
      execute("ALTER TABLE #{table} DROP COLUMN IF EXISTS search_vector")
    end

    execute("DROP FUNCTION IF EXISTS kiln_search_vector_refresh()")
    execute("DROP FUNCTION IF EXISTS kiln_regconfig(text)")
  end
end
