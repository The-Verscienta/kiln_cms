defmodule KilnCMS.Search.IdfCoverage do
  @moduledoc """
  The IDF-coverage measure behind `KilnCMS.Search.keyword_any_idf_coverage/0`
  (#1936): for each of a section's hits, the share of the query's IDF mass
  carried by the query lexemes the hit matches.

  Every choice here is part of the variant the issue preregistered, so it is
  spelled out once, here and on `keyword_any_idf_coverage/0`, and nowhere
  else:

    * **Lexemes** — the operands of `plainto_tsquery(kiln_regconfig(locale),
      query)`, the tsquery the keyword legs build. That is the real
      `to_tsvector` parse of the query under the locale's text-search config,
      Han and hyphen handling included, with no splitting of our own. Each
      lexeme counts once.
    * **The last lexeme matches as a prefix** (`'x':*`), produced by the same
      in-SQL rewrite `:search_any` applies, so a hit matched on the word still
      being typed is credited with it.
    * **IDF** — per section (one content resource, in the query's locale),
      over the **published** documents' `search_vector`:
      `ln(1 + (N - df + 0.5) / (df + 0.5))`, the smoothed BM25/Lucene form.
      Positive for every `df` in `0..N`: a lexeme every document carries
      weighs close to nothing rather than below nothing, and one no published
      document carries weighs most.
    * **Coverage** — the summed IDF of the lexemes a hit matches over the
      summed IDF of all of the query's, in `[0, 1]`.

  Both reads go through the content resource's own primary read under the
  caller's read options — the same `:actor`, `:authorize?` and `:tenant` the
  keyword legs ran under — so the corpus is exactly the published rows of
  this organisation the caller may read. A count never spans another
  organisation's rows, which a raw `SELECT count(*)` would.

  User text never reaches `to_tsquery/2`: each operand is cut from
  `plainto_tsquery`'s own text form, as the keyword legs' rewrites are.
  """

  require Ash.Query
  import Ash.Expr, only: [expr: 1]

  # One aggregate query carries `N` and up to this many `df` counts as
  # `count(*) FILTER (WHERE …)` columns. Names are a fixed, compile-time pool
  # so no atom is minted per query; a query with more distinct lexemes than
  # this (a pasted paragraph) runs one more aggregate per chunk.
  @chunk 32
  @df_names for i <- 1..@chunk, do: :"df_#{i}"

  # `plainto_tsquery`'s text form is `'a' & 'b' & 'c'` — operands joined by
  # ` & `, which is what `:search_any`'s rewrite to ` | ` relies on too. The
  # last operand gets `:*` exactly as the keyword legs' prefix rewrite does.
  # `WITH ORDINALITY` keeps the query's own order.
  @lexemes_sql """
  SELECT item
  FROM regexp_split_to_table(
         regexp_replace(plainto_tsquery(kiln_regconfig($1), $2)::text, '''$', ''':*'),
         ' & '
       ) WITH ORDINALITY AS t(item, n)
  ORDER BY n
  """

  @doc """
  `%{id => coverage}` for each of `ids` the caller can read, against `query`
  in `locale` over `resource`'s published documents. Empty when the query has
  no lexemes (all stop words) or `ids` is empty.
  """
  @spec coverages(module(), String.t(), String.t(), [Ash.UUID.t()], keyword()) ::
          %{Ash.UUID.t() => float()}
  def coverages(_resource, _query, _locale, [], _read_opts), do: %{}

  def coverages(resource, query, locale, ids, read_opts) do
    case lexemes(query, locale) do
      [] ->
        %{}

      lexemes ->
        weights = idf(resource, locale, lexemes, read_opts)
        total = Enum.sum(weights)

        resource
        |> matches(ids, lexemes, read_opts)
        |> Map.new(fn {id, matched} -> {id, matched_mass(matched, weights) / total} end)
    end
  end

  # The summed IDF of the lexemes a row matched; `matched` and `weights` are
  # both aligned with the query's lexemes.
  defp matched_mass(matched, weights) do
    matched
    |> Enum.zip(weights)
    |> Enum.reduce(0.0, fn
      {true, weight}, acc -> acc + weight
      {_miss, _weight}, acc -> acc
    end)
  end

  @doc """
  The query's lexemes as tsquery operands (`'pad'`, `'noodl':*`), in query
  order, each once. A lexeme that occurs both whole and as the trailing
  prefix keeps the prefix form, which matches everything the whole form does.
  """
  @spec lexemes(String.t(), String.t()) :: [String.t()]
  def lexemes(query, locale) do
    %{rows: rows} = KilnCMS.Repo.query!(@lexemes_sql, [locale, query])

    operands = for [item] <- rows, item != "", do: item
    prefixed = MapSet.new(for item <- operands, String.ends_with?(item, ":*"), do: base(item))

    operands
    |> Enum.uniq_by(&base/1)
    |> Enum.map(fn item ->
      if MapSet.member?(prefixed, base(item)), do: base(item) <> ":*", else: item
    end)
  end

  defp base(item), do: String.replace_suffix(item, ":*", "")

  # Each whitespace-separated query word with the operands its own
  # `plainto_tsquery` parse yields, in query order — how `term_matches/5`
  # names a lexeme by the word a caller typed. A word may yield several
  # (a hyphenated compound) or none (a stop word).
  @words_sql """
  SELECT w.word, op
  FROM unnest(regexp_split_to_array(trim($2), '\\s+')) WITH ORDINALITY AS w(word, n),
       regexp_split_to_table(plainto_tsquery(kiln_regconfig($1), w.word)::text, ' & ') AS op
  WHERE op <> ''
  ORDER BY w.n
  """

  @doc """
  The query's terms and which of them each of `ids` matches — the coverage
  `KilnCMS.Search.hit_explain/1` reports, as opposed to `coverages/5`'s
  IDF-weighted share.

  Returns `{terms, %{id => [matched?]}}`. `terms` is one
  `%{term: word, lexeme: lexeme}` per operand of `lexemes/2`, in query
  order, where `word` is the query word whose parse yields that lexeme (the
  lexeme itself when no single word does — a Han run the config splits
  differently in context); the booleans are aligned with `terms`. A row
  matches a term exactly as the keyword legs match it, the trailing one as
  a prefix. Read through the resource under `read_opts`, like `coverages/5`;
  `{[], %{}}` when the query has no lexemes or `ids` is empty.
  """
  @spec term_matches(module(), String.t(), String.t(), [Ash.UUID.t()], keyword()) ::
          {[%{term: String.t(), lexeme: String.t()}], %{Ash.UUID.t() => [boolean()]}}
  def term_matches(_resource, _query, _locale, [], _read_opts), do: {[], %{}}

  def term_matches(resource, query, locale, ids, read_opts) do
    case lexemes(query, locale) do
      [] ->
        {[], %{}}

      lexemes ->
        %{rows: rows} = KilnCMS.Repo.query!(@words_sql, [locale, query])

        words =
          Enum.reduce(Enum.reverse(rows), %{}, fn [w, op], acc -> Map.put(acc, plain(op), w) end)

        terms =
          Enum.map(lexemes, fn item ->
            lexeme = plain(item)
            %{term: Map.get(words, lexeme, lexeme), lexeme: lexeme}
          end)

        {terms, Map.new(matches(resource, ids, lexemes, read_opts))}
    end
  end

  # `'noodl':*` → `noodl`.
  defp plain(item), do: item |> base() |> String.trim("'")

  # `[idf]`, aligned with `lexemes`. Each operand is matched the way the
  # keyword legs match their whole query — `search_vector @@
  # to_tsquery('simple', …)` — one operand at a time.
  defp idf(resource, locale, lexemes, read_opts) do
    published =
      Ash.Query.filter(resource, state == :published and locale == ^locale)

    agg_opts = Keyword.take(read_opts, [:actor, :authorize?, :tenant])

    lexemes
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      named = Enum.zip(@df_names, chunk)

      counts =
        Ash.aggregate!(
          published,
          [
            {:n, :count}
            | Enum.map(named, fn {name, lexeme} ->
                {name, :count,
                 query: [
                   filter: expr(fragment("search_vector @@ to_tsquery('simple', ?)", ^lexeme))
                 ]}
              end)
          ],
          agg_opts
        )

      n = counts.n
      Enum.map(named, fn {name, _lexeme} -> weight(n, Map.fetch!(counts, name)) end)
    end)
  end

  defp weight(n, df), do: :math.log(1 + (n - df + 0.5) / (df + 0.5))

  # `[{id, [matched?]}]`, the booleans aligned with `lexemes`.
  defp matches(resource, ids, lexemes, read_opts) do
    resource
    |> Ash.Query.new()
    |> Ash.Query.select([:id])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.calculate(
      :idf_coverage_matches,
      {:array, :boolean},
      expr(
        fragment(
          "ARRAY(SELECT search_vector @@ to_tsquery('simple', u.q) FROM unnest(?::text[]) WITH ORDINALITY AS u(q, n) ORDER BY u.n)",
          ^lexemes
        )
      )
    )
    |> Ash.read!(read_opts)
    |> Enum.map(&{&1.id, &1.calculations.idf_coverage_matches})
  end
end
