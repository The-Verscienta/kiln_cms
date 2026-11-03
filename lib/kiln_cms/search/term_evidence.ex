defmodule KilnCMS.Search.TermEvidence do
  @moduledoc """
  The term-evidence gate behind `KilnCMS.Search.term_gate/0` (A6): what a
  query's own words say about whether a section holds anything it could mean.

  A fused score cannot separate a typo from junk. Both arrive with an empty
  keyword leg, and both are answered only by the legs that always answer —
  the semantic legs' nearest neighbours, the any-term relaxation's one shared
  word, the trigram guesses — so a threshold on the score or the distance
  that rejects "taylor swift tour dates" rejects "gui zi tang" with it. What
  does separate them is the vocabulary: every word of a typo query is in the
  corpus or one edit from a record's name; most words of a junk query are
  nowhere.

  Each **term** of the query — a word the locale's text-search config keeps
  (stop words drop out), lower-cased and accent-folded — is judged three
  ways against one section (one content resource, in the query's locale,
  read under the caller's read options, so tenancy and policies scope the
  vocabulary as they scope the legs):

    * **in the vocabulary** — some record's `search_vector` holds it, matched
      the way the keyword legs match: the term's own `plainto_tsquery` lexeme,
      the query's last term as a prefix (`'x':*`);
    * **a name** — some record's title, or a field flagged `names_record`
      (`KilnCMS.CMS.NameFields`), has it as a word;
    * **near a name** — some record's name has a word within `d(len)` edits
      of it (`levenshtein_less_equal`, from `fuzzystrmatch`), where `len` is
      the term's length: no edit under `:one_typo_length`, one from there,
      two from `:two_typo_length`. Only names are searched for near misses:
      a body vocabulary is large enough that every short word is one edit
      from something.

  The **share** is the fraction of terms in the vocabulary or near a name.
  The query is **junk** when the share falls below `:min_share` — or below
  the laxer `:min_share_named` when some term is a name outright, since a
  query that names a record on one word has said what it is about. A
  non-junk query whose terms include one that is near a name but not a name
  itself is a **typo**, and carries the correction: the nearest name word
  for each such term, which `KilnCMS.Search.hybrid/3` hands the fuzzy leg.

  Three reads at most, and only when the keyword leg came back empty — a
  keyword hit means every term is in the vocabulary, so there is nothing to
  judge: one `exists` aggregate for every term's three judgements, then, for
  a typo, one read of up to `@correction_rows` names near its terms.
  """

  require Ash.Query
  require Ash.Sort
  import Ash.Expr, only: [expr: 1]

  defstruct terms: [], share: 1.0, named?: false, corrections: %{}, verdict: :ok

  @typedoc """
  One judged query: its terms, the share of them with evidence, whether one
  is a name outright, the corrections for the ones only near a name, and the
  verdict — `:ok` (nothing to gate), `:typo` (corrections apply) or `:junk`.
  """
  @type t :: %__MODULE__{
          terms: [String.t()],
          share: float(),
          named?: boolean(),
          corrections: %{String.t() => String.t()},
          verdict: :ok | :typo | :junk
        }

  @typedoc "The gate's settings, as `KilnCMS.Search.term_gate/0` returns them."
  @type gate :: %{
          min_share: float(),
          min_share_named: float(),
          one_typo_length: pos_integer(),
          two_typo_length: pos_integer()
        }

  # One aggregate carries three judgements per term, named from a fixed,
  # compile-time pool so no atom is minted per query. A query with more terms
  # than this is a pasted paragraph, not junk to gate, and is left alone.
  @max_terms 16
  @vocab for i <- 1..@max_terms, do: :"vocab_#{i}"
  @name for i <- 1..@max_terms, do: :"name_#{i}"
  @near for i <- 1..@max_terms, do: :"near_#{i}"

  # A word longer than this is compared exactly: `levenshtein_less_equal`
  # refuses arguments over 255 characters, and nobody typos a 64-letter word.
  @max_fuzzy_length 64

  # Names read for the corrections. Enough for a few typo terms each to find
  # their nearest name; the correction steers a reduced-weight leg, it does
  # not gate anything.
  @correction_rows 20

  @terms_sql """
  SELECT u.w, plainto_tsquery(kiln_regconfig($1), u.w)::text
  FROM unnest($2::text[]) WITH ORDINALITY AS u(w, n)
  ORDER BY u.n
  """

  @doc """
  Judges `query` against `resource`'s vocabulary in `locale` — see the
  moduledoc. `gate` is `KilnCMS.Search.term_gate/0`'s map.
  """
  @spec assess(module(), String.t(), String.t(), keyword(), gate()) :: t()
  def assess(resource, query, locale, read_opts, gate) do
    case terms(query, locale) do
      [] -> %__MODULE__{}
      terms when length(terms) > @max_terms -> %__MODULE__{terms: Enum.map(terms, & &1.word)}
      terms -> judge(resource, locale, terms, read_opts, gate)
    end
  end

  @doc """
  The query's terms: each distinct word the locale's text-search config keeps,
  folded, with the tsquery text its exact match uses — the last one as a
  prefix, as the keyword legs match it.
  """
  @spec terms(String.t(), String.t()) :: [%{word: String.t(), tsquery: String.t()}]
  def terms(query, locale) do
    case words(query) do
      [] ->
        []

      words ->
        %{rows: rows} = KilnCMS.Repo.query!(@terms_sql, [locale, words])

        terms =
          rows
          |> Enum.reject(fn [_word, tsquery] -> tsquery == "" end)
          |> Enum.uniq_by(fn [word, _tsquery] -> word end)

        last = length(terms) - 1

        terms
        |> Enum.with_index()
        |> Enum.map(fn {[word, tsquery], index} ->
          %{word: word, tsquery: if(index == last, do: prefix(tsquery), else: tsquery)}
        end)
    end
  end

  # `'x'` → `'x':*`, the keyword legs' rewrite of their last lexeme.
  defp prefix(tsquery), do: String.replace(tsquery, ~r/'$/, "':*")

  @doc """
  The edit budget for a term of `length` letters: `0` below
  `:one_typo_length`, `1` from there, `2` from `:two_typo_length`.
  """
  @spec edits(non_neg_integer(), gate()) :: 0..2
  def edits(length, _gate) when length > @max_fuzzy_length, do: 0
  def edits(length, %{two_typo_length: two}) when length >= two, do: 2
  def edits(length, %{one_typo_length: one}) when length >= one, do: 1
  def edits(_length, _gate), do: 0

  defp judge(resource, locale, terms, read_opts, gate) do
    terms = Enum.map(terms, &Map.put(&1, :edits, edits(String.length(&1.word), gate)))
    names = name_fields(resource, read_opts)

    found =
      resource
      |> Ash.Query.filter(locale == ^locale)
      |> Ash.aggregate!(
        aggregates(terms, names),
        Keyword.take(read_opts, [:actor, :authorize?, :tenant])
      )

    judged =
      terms
      |> Enum.with_index()
      |> Enum.map(fn {term, i} ->
        Map.merge(term, %{
          vocab?: found[Enum.at(@vocab, i)] == true,
          name?: found[Enum.at(@name, i)] == true,
          near?: found[Enum.at(@near, i)] == true
        })
      end)

    evidenced = Enum.count(judged, &(&1.vocab? or &1.name? or &1.near?))
    share = evidenced / length(judged)
    named? = Enum.any?(judged, & &1.name?)
    bar = if named?, do: gate.min_share_named, else: gate.min_share

    words = Enum.map(judged, & &1.word)

    if share < bar do
      %__MODULE__{terms: words, share: share, named?: named?, verdict: :junk}
    else
      # Every term near a name is a candidate — a name word itself too: "zi"
      # names Wu Wei Zi and is still the typo in "gui zi tang". Corrections
      # come from the records' own names: a tag's word cannot be put back
      # into a title search.
      candidates = Enum.filter(judged, & &1.near?)
      own = Enum.reject(names, &match?({:tags, nil}, &1))
      corrections = corrections(resource, locale, candidates, own, read_opts, words)

      %__MODULE__{
        terms: words,
        share: share,
        named?: named?,
        corrections: corrections,
        verdict: if(corrections == %{}, do: :ok, else: :typo)
      }
    end
  end

  # The name sources: the title, each field flagged as a name, and the names
  # of the tags the records carry — a tag names what its records are about,
  # and the tag leg answers a query by it.
  defp name_fields(resource, read_opts) do
    tags = if Ash.Resource.Info.relationship(resource, :tags), do: [{:tags, nil}], else: []

    [{:title, nil}] ++
      Enum.map(KilnCMS.CMS.NameFields.for_resource(resource, read_opts[:tenant]), &{:custom, &1}) ++
      tags
  end

  defp aggregates(terms, names) do
    terms
    |> Enum.with_index()
    |> Enum.flat_map(fn {term, i} ->
      [
        {Enum.at(@vocab, i), :exists,
         query: [
           filter: expr(fragment("search_vector @@ to_tsquery('simple', ?)", ^term.tsquery))
         ]},
        {Enum.at(@name, i), :exists, query: [filter: names_within(names, term.word, 0)]},
        {Enum.at(@near, i), :exists, query: [filter: names_within(names, term.word, term.edits)]}
      ]
    end)
  end

  # Some name of the row has a word within `edits` of `word`.
  defp names_within(names, word, edits) do
    names
    |> Enum.map(&name_within(&1, word, edits))
    |> Enum.reduce(&expr(^&2 or ^&1))
  end

  # Each name source is matched by the same SQL, handed in as an expression;
  # a tag's name through the relationship.
  defp name_within({:tags, nil}, word, edits) do
    inner = name_within({:tag_name, nil}, word, edits)
    expr(exists(tags, ^inner))
  end

  defp name_within(name, word, 0) do
    expr(
      fragment(
        "EXISTS (SELECT 1 FROM regexp_split_to_table(lower(unaccent(coalesce(?, ''))), '[^[:alnum:]]+') AS w(word) WHERE w.word = ?)",
        ^name_source(name),
        ^word
      )
    )
  end

  # The length bound runs first and keeps `levenshtein_less_equal` off a
  # word it would refuse (over 255 characters); `CASE` fixes that order,
  # which `AND` alone does not.
  defp name_within(name, word, edits) do
    expr(
      fragment(
        "EXISTS (SELECT 1 FROM regexp_split_to_table(lower(unaccent(coalesce(?, ''))), '[^[:alnum:]]+') AS w(word) WHERE CASE WHEN w.word <> '' AND abs(length(w.word) - length(?)) <= ? THEN levenshtein_less_equal(w.word, ?, ?) <= ? ELSE false END)",
        ^name_source(name),
        ^word,
        ^edits,
        ^word,
        ^edits,
        ^edits
      )
    )
  end

  defp name_source({:title, nil}), do: expr(title)
  defp name_source({:tag_name, nil}), do: expr(name)
  defp name_source({:custom, field}), do: expr(fragment("? ->> ?::text", custom_fields, ^field))

  # `%{typo => name word}`: the names near the candidate terms, read once —
  # the rows near the most of them first — and each candidate corrected to
  # the word, among them, of the name that shares most of the query's other
  # terms: "huang qui" is one edit from both "gui" and "qi", and only Huang Qi
  # is also named "huang"; "zi" is a name on its own, and Gui Zhi Tang still
  # shares "gui" and "tang". Then the fewest edits, then the commonest word.
  # A candidate whose best word is itself is no typo.
  defp corrections(_resource, _locale, [], _names, _read_opts, _terms), do: %{}

  defp corrections(resource, locale, candidates, names, read_opts, terms) do
    near = Enum.map(candidates, &names_within(names, &1.word, &1.edits))

    near_count =
      near
      |> Enum.map(&expr(type(fragment("CASE WHEN ? THEN 1 ELSE 0 END", ^&1), :integer)))
      |> Enum.reduce(&expr(^&2 + ^&1))

    rows =
      resource
      |> Ash.Query.filter(locale == ^locale)
      |> Ash.Query.filter(^Enum.reduce(near, &expr(^&2 or ^&1)))
      |> Ash.Query.select([:id, :title] ++ custom_fields_select(names))
      |> Ash.Query.sort([{Ash.Sort.expr_sort(^near_count, :integer), :desc}])
      |> Ash.Query.limit(@correction_rows)
      |> Ash.read!(read_opts)
      |> Enum.map(&name_words(&1, names))

    frequency = rows |> List.flatten() |> Enum.frequencies()

    for candidate <- candidates,
        best = best_word(candidate, rows, terms, frequency),
        best not in [nil, candidate.word],
        into: %{},
        do: {candidate.word, best}
  end

  defp custom_fields_select(names),
    do: if(Enum.any?(names, &match?({:custom, _}, &1)), do: [:custom_fields], else: [])

  defp name_words(record, names) do
    names
    |> Enum.flat_map(fn
      {:title, nil} -> [record.title]
      {:custom, field} -> List.wrap(get_in(record.custom_fields || %{}, [field]))
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&words/1)
  end

  @doc """
  A word folded the way terms are: lower-cased, decomposed, the combining
  marks dropped — what `unaccent` does for the Latin scripts names are typed
  in, so a folded term compares equal to the SQL side's
  `lower(unaccent(name))` word.
  """
  @spec fold(String.t()) :: String.t()
  def fold(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp words(text), do: ~r/[\p{L}\p{N}]+/u |> Regex.scan(fold(text)) |> List.flatten()

  defp best_word(candidate, rows, terms, frequency) do
    others = MapSet.new(terms -- [candidate.word])

    rows
    |> Enum.flat_map(fn words ->
      shared = words |> MapSet.new() |> MapSet.intersection(others) |> MapSet.size()
      for word <- words, do: {word, levenshtein(candidate.word, word), shared}
    end)
    |> Enum.filter(fn {_word, distance, _shared} -> distance <= candidate.edits end)
    |> Enum.min_by(fn {word, distance, shared} -> {-shared, distance, -frequency[word]} end, fn ->
      nil
    end)
    |> case do
      {word, _distance, _shared} -> word
      nil -> nil
    end
  end

  @doc "Edit distance between two strings, by grapheme (insert, delete, substitute)."
  @spec levenshtein(String.t(), String.t()) :: non_neg_integer()
  def levenshtein(a, b) do
    b = String.graphemes(b)

    a
    |> String.graphemes()
    |> Enum.reduce(Enum.to_list(0..length(b)), &next_row(&1, &2, b))
    |> List.last()
  end

  # One row of the edit-distance table: `previous` is the row above, `char`
  # the next grapheme of the first string, `b` the second string's.
  defp next_row(char, [first | rest] = previous, b) do
    previous
    |> Enum.zip(rest)
    |> Enum.zip(b)
    |> Enum.reduce({[first + 1], first + 1}, fn {{diagonal, above}, other}, {row, left} ->
      cell = Enum.min([left + 1, above + 1, diagonal + if(char == other, do: 0, else: 1)])
      {[cell | row], cell}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
