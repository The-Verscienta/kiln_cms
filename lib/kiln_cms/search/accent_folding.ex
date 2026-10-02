defmodule KilnCMS.Search.AccentFolding do
  @moduledoc """
  Accent-folding full-text search (#1628): `Zusanli` finds `Zúsānlǐ`, `creme
  brulee` finds `Crème brûlée`, and the other way round.

  Every full-text leg of search — keyword, any-term, title, alias, prefix and
  the highlight snippet — resolves its text-search configuration through one
  SQL function, `kiln_regconfig(locale)`. The stock configurations it used to
  return (`english`, `french`, …) keep diacritics, so the two spellings were
  different lexemes and only a reader who typed the marks found the record.

  This is an `AshPostgres.CustomExtension`, listed in
  `KilnCMS.Repo.installed_extensions/0`, so `mix ash.codegen` writes the
  migration that installs it. Version 1:

    * creates Postgres's `unaccent` extension (contrib; a *trusted* extension,
      so the database owner can create it without superuser);
    * creates one configuration per language, `kiln_<language>`, a copy of
      the stock one whose dictionary chain for non-ASCII words starts with
      `unaccent` — the accents are folded *before* stemming, on both the
      indexed and the query side, since both go through `kiln_regconfig/1`;
    * points `kiln_regconfig/1` at them. Its body is a SQL-standard
      (`BEGIN ATOMIC`) body, so each configuration is resolved to its OID
      when the function is created rather than by name on every call: the
      function stays correct under any `search_path`, including the empty
      one `pg_dump` restores with, which is when the expression indexes that
      call it are rebuilt;
    * rebuilds what was computed with the old configurations: every index
      whose expression calls `kiln_regconfig` (the title-lexeme indexes), and
      the stored `search_vector` of every row whose title or `search_text`
      holds a non-ASCII character. A pure-ASCII text produces only ASCII
      tokens, which the new configurations map exactly as the old ones did,
      so those rows are already right and are not rewritten.

  `to_tsvector(regconfig, text)` is `IMMUTABLE` whatever the configuration,
  so the expression indexes over `kiln_regconfig/1` remain usable. The
  trigram (`pg_trgm`) title indexes behind autocomplete and the fuzzy leg are
  not touched by this: they compare characters, not lexemes.
  """
  use AshPostgres.CustomExtension, name: "kiln_accent_folding", latest_version: 1

  # locale prefix => {stock configuration, its stemming dictionary}. The
  # language list is the one `kiln_regconfig/1` has always mapped; anything
  # else is `simple`, folded the same way.
  @languages [
    {"en", "english", "english_stem"},
    {"fr", "french", "french_stem"},
    {"de", "german", "german_stem"},
    {"es", "spanish", "spanish_stem"},
    {"it", "italian", "italian_stem"},
    {"pt", "portuguese", "portuguese_stem"},
    {"nl", "dutch", "dutch_stem"},
    {"ru", "russian", "russian_stem"},
    {"sv", "swedish", "swedish_stem"},
    {"no", "norwegian", "norwegian_stem"},
    {"da", "danish", "danish_stem"},
    {"fi", "finnish", "finnish_stem"}
  ]

  @fallback {"simple", "simple"}

  @doc "The folded configuration name for a stock one (`\"english\"` → `\"kiln_english\"`)."
  @spec config_name(String.t()) :: String.t()
  def config_name(stock), do: "kiln_" <> stock

  @impl true
  def install(0) do
    """
    execute("CREATE EXTENSION IF NOT EXISTS unaccent")

    execute(\"\"\"
    #{create_configs_sql()}
    \"\"\")

    execute(\"\"\"
    #{regconfig_sql(&config_name/1)}
    \"\"\")

    execute(\"\"\"
    #{reindex_sql()}
    \"\"\")

    execute(\"\"\"
    #{backfill_sql()}
    \"\"\")
    """
  end

  @impl true
  def uninstall(1) do
    drops =
      Enum.map_join(configs(), "\n", fn {stock, _dict} ->
        ~s|execute("DROP TEXT SEARCH CONFIGURATION IF EXISTS #{config_name(stock)}")|
      end)

    """
    execute(\"\"\"
    #{regconfig_sql(& &1)}
    \"\"\")

    #{drops}
    """
  end

  defp configs, do: Enum.map(@languages, fn {_prefix, stock, dict} -> {stock, dict} end) ++ [@fallback]

  # Guarded, so a re-run (or a database restored with the configurations
  # already in it) is a no-op. Only the non-ASCII token types are remapped:
  # the ASCII ones carry nothing to fold.
  defp create_configs_sql do
    statements =
      Enum.map_join(configs(), "\n", fn {stock, dict} ->
        name = config_name(stock)

        """
          IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname = '#{name}' AND cfgnamespace = current_schema()::regnamespace) THEN
            CREATE TEXT SEARCH CONFIGURATION #{name} (COPY = pg_catalog.#{stock});
            ALTER TEXT SEARCH CONFIGURATION #{name}
              ALTER MAPPING FOR word, hword, hword_part WITH unaccent, #{dict};
          END IF;
        """
      end)

    "DO $kiln$\nBEGIN\n#{statements}END\n$kiln$"
  end

  defp regconfig_sql(name_fun) do
    whens =
      Enum.map_join(@languages, "\n", fn {prefix, stock, _dict} ->
        "    WHEN '#{prefix}' THEN '#{name_fun.(stock)}'::regconfig"
      end)

    """
    CREATE OR REPLACE FUNCTION kiln_regconfig(loc text) RETURNS regconfig
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    BEGIN ATOMIC
      SELECT CASE lower(left(coalesce(loc, ''), 2))
    #{whens}
        ELSE '#{name_fun.(elem(@fallback, 0))}'::regconfig
      END;
    END\
    """
  end

  defp reindex_sql do
    """
    DO $kiln$
    DECLARE idx regclass;
    BEGIN
      FOR idx IN
        SELECT i.indexrelid::regclass
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relnamespace = current_schema()::regnamespace
          AND pg_get_indexdef(i.indexrelid) LIKE '%kiln_regconfig%'
      LOOP
        EXECUTE format('REINDEX INDEX %s', idx);
      END LOOP;
    END
    $kiln$\
    """
  end

  # The trigger (`kiln_search_vector_refresh`) recomputes only when the title,
  # `search_text` or locale changes, so the vector is set here directly.
  defp backfill_sql do
    """
    DO $kiln$
    DECLARE tbl text;
    BEGIN
      FOR tbl IN
        SELECT c.table_name
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.column_name = 'search_vector'
          AND EXISTS (SELECT 1 FROM information_schema.columns t
                      WHERE t.table_schema = c.table_schema AND t.table_name = c.table_name
                        AND t.column_name = 'search_text')
      LOOP
        EXECUTE format(
          'UPDATE %I SET search_vector = '
          'setweight(to_tsvector(kiln_regconfig(locale), coalesce(title, '''')), ''A'') || '
          'setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_text, '''')), ''B'') '
          'WHERE octet_length(coalesce(title, '''') || coalesce(search_text, '''')) '
          '<> char_length(coalesce(title, '''') || coalesce(search_text, ''''))',
          tbl);
      END LOOP;
    END
    $kiln$\
    """
  end
end
