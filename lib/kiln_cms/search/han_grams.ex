defmodule KilnCMS.Search.HanGrams do
  @moduledoc """
  Han (CJK ideograph) text as character bigrams, so full-text search finds a
  Chinese word inside a longer Chinese run (A8).

  Postgres's text-search parser has no Chinese segmenter. Han text carries no
  spaces, so the parser reads each unbroken run of ideographs as one word:
  `本方以吴茱萸为君药` is a single lexeme, and neither `吴茱萸` nor `茱萸`
  matches it. A run only splits where punctuation or a space happens to fall,
  so a name was findable in an ingredient list (`黄连、黄芩`) and invisible in
  a sentence. The keyword leg's prefix match covers a name at the start of a
  run (`黄连` finds `黄连解毒汤`) and nothing else.

  The standard answer without a dictionary is n-grams. This is an
  `AshPostgres.CustomExtension`, listed in `KilnCMS.Repo.installed_extensions/0`,
  so `mix ash.codegen` writes the migration that installs it. Version 1:

    * creates `kiln_han_runs(text)`, the text's runs of Han ideographs in
      order, as `text[]`;
    * creates `kiln_han_grams(text)`, those runs as overlapping character
      bigrams, space-separated (`吴茱萸汤` → `吴茱 茱萸 萸汤`) — a run of one
      character is kept as that one character (a unigram), and nothing else
      is emitted as one;
    * creates `kiln_han_tsquery(text)`, a query's runs in the same shape:
      each run its bigrams as a phrase (`'吴茱' <-> '茱萸'`), a
      one-character run a prefix (`'黄':*`, which matches the bigrams that
      begin with it), the runs ANDed — or `NULL` when the text holds no Han,
      so `search_vector @@ kiln_han_tsquery(q)` is never true for it;
    * creates `kiln_search_vector(locale, title, search_text, weighted)`, the
      whole stored vector: what `search_vector` already held, followed by the
      bigrams of the same texts at the same weights, under
      `pg_catalog.simple`. With `weighted` — the row's four `search_weighted`
      buckets (#2183, A3) — that is the role-weighted vector, buckets `A`–`D`;
      without it (`NULL`: no such column, or a row not yet re-saved), title
      `A` and `search_text` `B`. For a text with no Han the bigram parts are
      empty and the vector is exactly the one A3's trigger built;
    * replaces the shared trigger function, `kiln_search_vector_refresh()`,
      with A3's own body — which branch a row takes and when its buckets are
      cleared as stale are unchanged — computing each branch's vector with
      `kiln_search_vector`, so every content table, core or overlay, picks it
      up with no per-table change;
    * rewrites the stored vector of every row whose title, `search_text` or
      buckets hold a Han character, in every table with a `search_vector`.
      A row without one already has the right vector and is not touched.

  The bigrams are appended after the other lexemes, never interleaved, so
  the positions of every other lexeme are unchanged and nothing a non-Han
  query ranks by moves.

  Nothing indexes an expression over these functions, so unlike
  `KilnCMS.Search.AccentFolding` nothing needs rebuilding. Their bodies are
  SQL-standard (`BEGIN ATOMIC`) all the same, so each resolves what it calls
  when it is created and is correct under any `search_path`.

  Expand-only: the previous release reads `search_vector` with queries that
  only ever name whole-run lexemes, which are still there, and the extra
  lexemes are ones no non-Han query produces. `uninstall/1` puts A3's trigger
  body back and drops the functions; the bigrams already stored stay until
  each row is next written, harmlessly.

  ## Which characters

  `@ranges` below: CJK Unified Ideographs and Extension A, the compatibility
  ideographs, and the supplementary-plane extensions B onwards. Kana and
  Hangul are not Han: Japanese kana and Korean words are delimited by
  script changes and spaces, which the parser already splits on. A
  Japanese kanji compound is Han and is bigrammed like Chinese.
  """
  use AshPostgres.CustomExtension, name: "kiln_han_grams", latest_version: 1

  # One character class, in both syntaxes: Postgres's regex (`\uXXXX`,
  # `\UXXXXXXXX`) for the SQL, PCRE (`\x{…}`) for `han?/1`, so the query
  # side's "does this query hold Han" and the SQL's split agree.
  @ranges [{0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xF900, 0xFAFF}, {0x20000, 0x3134F}]

  @sql_class "[" <>
               Enum.map_join(@ranges, fn {from, to} ->
                 esc = fn
                   cp when cp > 0xFFFF ->
                     "\\U" <> String.pad_leading(Integer.to_string(cp, 16), 8, "0")

                   cp ->
                     "\\u" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
                 end

                 esc.(from) <> "-" <> esc.(to)
               end) <> "]"

  @han Regex.compile!(
         "[" <>
           Enum.map_join(@ranges, fn {from, to} ->
             "\\x{#{Integer.to_string(from, 16)}}-\\x{#{Integer.to_string(to, 16)}}"
           end) <> "]",
         "u"
       )

  @doc """
  Whether `text` holds a Han ideograph — whether the Han legs of
  `KilnCMS.Search.hybrid/3` have anything to do for it.
  """
  @spec han?(String.t() | nil) :: boolean()
  def han?(text) when is_binary(text), do: Regex.match?(@han, text)
  def han?(_text), do: false

  @impl true
  def install(0) do
    Enum.join(
      [
        Enum.map_join(functions_sql(), "\n\n", &execute/1),
        execute(
          refresh_sql(
            "kiln_search_vector(NEW.locale, NEW.title, NEW.search_text, weighted)",
            "kiln_search_vector(NEW.locale, NEW.title, NEW.search_text, NULL)"
          )
        ),
        execute(backfill_sql())
      ],
      "\n\n"
    )
  end

  @impl true
  def uninstall(1) do
    Enum.join(
      [
        execute(refresh_sql(role_vector_sql("weighted", "NEW."), plain_vector_sql("NEW."))),
        ~s|execute("DROP FUNCTION IF EXISTS kiln_search_vector(text, text, text, text[])")|,
        ~s|execute("DROP FUNCTION IF EXISTS kiln_han_tsquery(text)")|,
        ~s|execute("DROP FUNCTION IF EXISTS kiln_han_grams(text)")|,
        ~s|execute("DROP FUNCTION IF EXISTS kiln_han_runs(text)")|
      ],
      "\n"
    )
  end

  # One migration `execute/1` call over a heredoc of `sql`, as source text.
  @heredoc String.duplicate(~s("), 3)
  defp execute(sql), do: "execute(#{@heredoc}\n#{escape(sql)}\n#{@heredoc})"

  # The SQL holds regex backslashes (`\u4E00`), which an Elixir heredoc would
  # read as escapes; the migration must carry them to Postgres as written.
  defp escape(sql), do: String.replace(sql, "\\", "\\\\")

  # The two vectors A3's trigger (`*_weighted_search_vector_trigger`, #2183)
  # builds, over `prefix`ed columns (`NEW.` in the trigger, none in a
  # function body taking them as arguments): from the four `search_weighted`
  # buckets in `weighted`, and from the title and `search_text`.
  defp role_vector_sql(weighted, prefix) do
    ~w(A B C D)
    |> Enum.with_index(1)
    |> Enum.map_join(" ||\n      ", fn {weight, i} ->
      "setweight(to_tsvector(kiln_regconfig(#{prefix}locale), coalesce(#{weighted}[#{i}], '')), '#{weight}')"
    end)
  end

  defp plain_vector_sql(prefix) do
    "setweight(to_tsvector(kiln_regconfig(#{prefix}locale), coalesce(#{prefix}title, '')), 'A') ||\n" <>
      "      setweight(to_tsvector(kiln_regconfig(#{prefix}locale), coalesce(#{prefix}search_text, '')), 'B')"
  end

  # The bigrams of each text, at its weight, under `pg_catalog.simple`.
  defp han_vector_sql(texts, weights) do
    texts
    |> Enum.zip(weights)
    |> Enum.map_join(" ||\n      ", fn {text, weight} ->
      "setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(#{text})), '#{weight}')"
    end)
  end

  # One statement each: a migration's `execute/1` runs a single statement.
  # `kiln_search_vector` names its arguments after the trigger's columns,
  # so the two A3 vectors read the same in both places.
  defp functions_sql do
    [
      """
      CREATE OR REPLACE FUNCTION kiln_han_runs(t text) RETURNS text[]
      LANGUAGE sql IMMUTABLE PARALLEL SAFE
      BEGIN ATOMIC
        SELECT coalesce(array_agg(m.r[1] ORDER BY m.n), '{}')
        FROM regexp_matches(coalesce(t, ''), '(#{@sql_class}+)', 'g') WITH ORDINALITY AS m(r, n);
      END\
      """,
      """
      CREATE OR REPLACE FUNCTION kiln_han_grams(t text) RETURNS text
      LANGUAGE sql IMMUTABLE PARALLEL SAFE
      BEGIN ATOMIC
        SELECT coalesce(string_agg(substr(r.run, g.i, 2), ' ' ORDER BY r.n, g.i), '')
        FROM unnest(kiln_han_runs(t)) WITH ORDINALITY AS r(run, n),
             generate_series(1, greatest(char_length(r.run) - 1, 1)) AS g(i);
      END\
      """,
      """
      CREATE OR REPLACE FUNCTION kiln_han_tsquery(t text) RETURNS tsquery
      LANGUAGE sql IMMUTABLE PARALLEL SAFE
      BEGIN ATOMIC
        SELECT CASE WHEN s.q = '' THEN NULL ELSE to_tsquery('pg_catalog.simple', s.q) END
        FROM (
          SELECT coalesce(string_agg(
            CASE WHEN char_length(r.run) = 1 THEN '''' || r.run || ''':*'
                 ELSE (SELECT string_agg('''' || substr(r.run, g.i, 2) || '''', ' <-> ' ORDER BY g.i)
                       FROM generate_series(1, char_length(r.run) - 1) AS g(i))
            END, ' & ' ORDER BY r.n), '') AS q
          FROM unnest(kiln_han_runs(t)) WITH ORDINALITY AS r(run, n)
        ) AS s;
      END\
      """,
      """
      CREATE OR REPLACE FUNCTION kiln_search_vector(locale text, title text, search_text text, weighted text[])
      RETURNS tsvector
      LANGUAGE sql IMMUTABLE PARALLEL SAFE
      BEGIN ATOMIC
        SELECT CASE WHEN cardinality(weighted) = 4 THEN
          #{role_vector_sql("weighted", "")} ||
          #{han_vector_sql(Enum.map(1..4, &"weighted[#{&1}]"), ~w(A B C D))}
        ELSE
          #{plain_vector_sql("")} ||
          #{han_vector_sql(~w(title search_text), ~w(A B))}
        END;
      END\
      """
    ]
  end

  # `*_weighted_search_vector_trigger`'s function (#2183, A3) as it stands,
  # with each of its two vectors passed in — the role-weighted one, for a
  # row with its four buckets, and the title/`search_text` one otherwise.
  # Which branch a row takes, and when its buckets are cleared as stale, is
  # A3's and unchanged.
  defp refresh_sql(weighted_vector_sql, plain_vector_sql) do
    """
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
            #{weighted_vector_sql};
        ELSE
          NEW.search_vector :=
            #{plain_vector_sql};
        END IF;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql\
    """
  end

  # The trigger recomputes only when the title, `search_text`, locale or
  # buckets change, so the vector is set here directly — from the buckets
  # where the table has `search_weighted`, as the trigger would. Public for
  # the test that re-runs it over a row stored the old way.
  @doc false
  def backfill_sql do
    """
    DO $kiln$
    DECLARE
      tbl text;
      buckets text;
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
        buckets := CASE WHEN EXISTS (
          SELECT 1 FROM information_schema.columns w
          WHERE w.table_schema = current_schema() AND w.table_name = tbl
            AND w.column_name = 'search_weighted'
        ) THEN 'search_weighted' ELSE 'NULL::text[]' END;

        EXECUTE format(
          'UPDATE %I SET search_vector = kiln_search_vector(locale, title, search_text, %s) '
          'WHERE coalesce(title, '''') || coalesce(search_text, '''') '
          '|| coalesce(array_to_string(%s, '' ''), '''') ~ ''#{@sql_class}''',
          tbl, buckets, buckets);
      END LOOP;
    END
    $kiln$\
    """
  end
end
