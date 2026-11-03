defmodule KilnCMS.Search.NameTerms do
  @moduledoc """
  Names written spaced or joined (Verscienta's proposal A5): `huangqi` for Huang Qi, `Xiao Yao
  San` for Xiaoyaosan, `He Gu` for Hegu, `SP 9` for SP9. Full-text search
  cannot see either pair as one name — `to_tsvector` splits on spaces and
  never inside a word — so the title and alias legs of
  `KilnCMS.Search.hybrid/3` missed every one of them, and the keyword leg
  matched only whatever spelling the body text happened to use.

  This module rewrites the query instead of the index. `variants/2` takes a
  query and the site's **name terms** — every word of every published
  title and every value of a field flagged `names_record`
  (`KilnCMS.CMS.NameFields`), lower-cased and accent-folded — and returns
  the query rewritten one span at a time:

    * **joins** — two or three adjacent query words concatenated, kept only
      when the concatenation is itself a name term (`he gu` → `hegu`);
    * **splits** — one query word cut into two or three parts, kept only
      when every part is a name term (`xiaoyaosan` → `xiao yao san`).

  Each variant carries its **span**: the joined word, or the split parts as
  a phrase. The compound leg (`:search_compound`, built by `KilnCMS.CMS.Content`)
  matches a record when its name
  occurs in a variant the way the title leg matches a name in the query,
  *and* the span occurs in that name. The second half is what keeps a
  split honest: `carpet` → `car pet` names a record called "Car Pet", never
  one called "Car". The dictionary gate keeps the leg free — a query with
  no word to join or split has no variants, and the leg does not run.

  The dictionary is per site (organization), over its **published** rows:
  a split it allows can only ever match a record whose name holds the
  parts, and every such record a reader can see is published, so a draft's
  words would add a rewrite and no match. Cached per site for
  five minutes under the type registry's gate
  (`KilnCMS.CMS.ContentTypes.cache_registry?/0`), so a name published a
  moment ago is joined or split once the entry expires; until then it is
  still found by every other leg.
  """

  require Ash.Query
  import Ash.Expr, only: [expr: 1]

  alias KilnCMS.Cache
  alias KilnCMS.CMS.ContentTypes

  @ttl :timer.minutes(5)

  # A word longer than this is not split: no name is one 33-character word,
  # and the three-way splits grow with the square of the length.
  @max_split_length 32

  # The query word is folded the way `unaccent` folds the dictionary side,
  # then split into the runs of letters and digits `to_tsvector` would see.
  @word ~r/[\p{L}\p{N}]+/u

  # Bounds the leg's work on a pathological query (a long run of short name
  # terms joins and splits many ways); a real query has a handful at most.
  @max_variants 16

  @typedoc "A rewritten query and the span the rewrite produced."
  @type variant :: {query :: String.t(), span :: String.t()}

  @doc """
  The site's name terms, a `MapSet` of lower-cased, accent-folded words.
  `tenant` is an organization, its id, or `nil` for the default org.
  """
  @spec dictionary(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: MapSet.t()
  def dictionary(tenant) do
    org_id = KilnCMS.Accounts.org_id(tenant)

    if ContentTypes.cache_registry?() do
      Cache.fetch(Cache.name_terms_key(org_id), @ttl, fn -> load(org_id) end)
    else
      load(org_id)
    end
  end

  @doc """
  The query rewritten one span at a time — joins first, then splits, each
  in query order — against `dictionary`. `[]` when nothing joins or splits
  into name terms, which is every query that does not write a name spaced
  or joined differently from the site.
  """
  @spec variants(String.t(), MapSet.t()) :: [variant()]
  def variants(query, dictionary) do
    words = words(query)

    if words == [] or MapSet.size(dictionary) == 0 do
      []
    else
      splits =
        for {word, i} <- Enum.with_index(words), parts <- splits(word, dictionary) do
          {replace(words, i, 1, parts), Enum.join(parts, " ")}
        end

      (joins(words, dictionary) ++ splits)
      |> Enum.uniq()
      |> Enum.take(@max_variants)
    end
  end

  # Every run of two or three adjacent words whose concatenation is a name term.
  defp joins(words, dictionary) do
    for n <- [2, 3],
        i <- 0..(length(words) - n)//1,
        joined = words |> Enum.slice(i, n) |> Enum.join(),
        MapSet.member?(dictionary, joined),
        do: {replace(words, i, n, [joined]), joined}
  end

  @doc false
  # The query's words as `variants/2` sees them. Public for the dictionary's
  # own tests, which fold a title through it to predict the terms.
  @spec words(String.t()) :: [String.t()]
  def words(text) do
    folded =
      text
      |> String.downcase()
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")

    @word |> Regex.scan(folded) |> List.flatten()
  end

  defp replace(words, i, n, with),
    do: (Enum.take(words, i) ++ with ++ Enum.drop(words, i + n)) |> Enum.join(" ")

  # Every cut of `word` into two or three name terms.
  defp splits(word, dictionary) do
    length = String.length(word)

    if length < 3 or length > @max_split_length do
      []
    else
      for a <- 1..(length - 1)//1,
          first = String.slice(word, 0, a),
          part?(first, dictionary),
          rest = String.slice(word, a..-1//1),
          parts <- [[rest] | three_way(rest, dictionary)],
          Enum.all?(parts, &part?(&1, dictionary)),
          do: [first | parts]
    end
  end

  defp three_way(rest, dictionary) do
    length = String.length(rest)

    for b <- 1..(length - 1)//1,
        second = String.slice(rest, 0, b),
        part?(second, dictionary),
        do: [second, String.slice(rest, b..-1//1)]
  end

  # A part is a name term; a one-letter part only when it is a number (the
  # `9` of `SP9`) — a lone letter is in nearly every dictionary, and would
  # split almost any word.
  defp part?(part, dictionary) do
    MapSet.member?(dictionary, part) and
      (String.length(part) > 1 or String.match?(part, ~r/^\p{N}$/u))
  end

  # System read, like `KilnCMS.CMS.NameFields`: the terms only decide which
  # rewrites the compound leg tries, and that leg reads under the caller's
  # policies, so nothing a reader may not see is reachable through them.
  # Published rows only (see the moduledoc), under the site's tenant. The
  # shared entry table is skipped on a site with no dynamic type, as the
  # search sweep skips its section there.
  defp load(org_id) do
    KilnCMS.Search.content_resources()
    |> Enum.reject(&(&1 == KilnCMS.CMS.Entry and ContentTypes.dynamic_all(org_id) == []))
    |> Enum.flat_map(&texts(&1, org_id))
    |> Enum.flat_map(&String.split(&1, ~r/[^\p{L}\p{N}]+/u, trim: true))
    |> MapSet.new()
  end

  # Each published row's title and flagged names as one folded string —
  # computed in the database, so a row's `custom_fields` never leaves it.
  defp texts(resource, org_id) do
    names = KilnCMS.CMS.NameFields.for_resource(resource, org_id)

    resource
    |> Ash.Query.new()
    |> Ash.Query.filter(state == :published)
    |> Ash.Query.select([:id])
    |> Ash.Query.calculate(:name_terms_text, :string, name_text(names))
    # authorize?: false — terms only steer rewrites; the compound leg reads under the caller's policies
    |> Ash.read!(tenant: org_id, authorize?: false)
    |> Enum.map(& &1.calculations.name_terms_text)
  end

  defp name_text(names) do
    Enum.reduce(names, expr(fragment("lower(unaccent(?))", title)), fn name, acc ->
      expr(
        fragment(
          "? || ' ' || lower(unaccent(coalesce((SELECT string_agg(value, ' ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(? -> ?::text) = 'array' THEN ? -> ?::text ELSE jsonb_build_array(coalesce(? ->> ?::text, '')) END)), '')))",
          ^acc,
          custom_fields,
          ^name,
          custom_fields,
          ^name,
          custom_fields,
          ^name
        )
      )
    end)
  end
end
