defmodule KilnCMS.Repo.Migrations.WeightedSearchVectorTrigger do
  @moduledoc """
  Weights `search_vector` by role (#2175 A3). `kiln_search_vector_refresh()`
  — the one trigger function every content table's `search_vector` trigger
  runs — builds the vector from `search_weighted`, the `[a, b, c, d]`
  buckets `KilnCMS.CMS.Changes.SetSearchText` writes beside `search_text`
  (title and name fields `A`, summary fields and the leading words of the
  searchable fields `B`, the rest of those `C`, the body `D`).

  Expand-safe for a rolling deploy:

    * a table without the column (an overlay that has not run
      `mix ash.codegen` yet) is detected per write and keeps the old vector,
      title `A` and `search_text` `B` — so this one function serves every
      table, and no table's trigger is recreated;
    * a row whose `search_weighted` is `nil` — every row until it is next
      saved or fired — keeps the old vector too;
    * an update that moves `title` or `search_text` and leaves
      `search_weighted` as it was comes from a writer that does not keep it
      (the previous release, mid-deploy): the buckets describe the old text,
      so they are cleared and the old vector is built instead.

  No backfill: the buckets are computed in Elixir (custom-field definitions,
  block text), not in SQL. A re-fire sweep (`mix kiln.refire_all`, or
  `KilnCMS.Firing.Sweep.run()` on a release) fills them in for published
  documents; a draft is filled on its next save.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION kiln_search_vector_refresh() RETURNS trigger AS $$
    DECLARE
      weighted text[];
      changed boolean;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        changed := true;
      ELSE
        changed := NEW.title IS DISTINCT FROM OLD.title
          OR NEW.search_text IS DISTINCT FROM OLD.search_text
          OR NEW.locale IS DISTINCT FROM OLD.locale;
      END IF;

      IF EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = TG_RELID AND attname = 'search_weighted' AND NOT attisdropped
      ) THEN
        weighted := NEW.search_weighted;

        IF TG_OP = 'UPDATE' THEN
          IF weighted IS DISTINCT FROM OLD.search_weighted THEN
            changed := true;
          ELSIF NEW.title IS DISTINCT FROM OLD.title
                OR NEW.search_text IS DISTINCT FROM OLD.search_text THEN
            weighted := NULL;
            NEW.search_weighted := NULL;
          END IF;
        END IF;
      END IF;

      IF changed THEN
        IF weighted IS NOT NULL AND cardinality(weighted) = 4 THEN
          NEW.search_vector :=
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(weighted[1], '')), 'A') ||
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(weighted[2], '')), 'B') ||
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(weighted[3], '')), 'C') ||
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(weighted[4], '')), 'D');
        ELSE
          NEW.search_vector :=
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.title, '')), 'A') ||
            setweight(to_tsvector(kiln_regconfig(NEW.locale), coalesce(NEW.search_text, '')), 'B');
        END IF;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)
  end

  def down do
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
    $$ LANGUAGE plpgsql
    """)
  end
end
