defmodule Mix.Tasks.Kiln.Search.MeasureFloor do
  @moduledoc """
  Measures where `semantic_max_distance` should sit for **this** corpus and
  embedder, from the golden set `mix kiln.search.eval` scores.

  `KilnCMS.Search.semantic_max_distance/0` ships as `nil` because the useful
  cutoff is a property of the model and the corpus: a number measured on a
  sample drifts as the corpus grows around it, and one measured for one
  embedder can silently empty another. The config comment tells operators to
  measure; this is the measurement.

  ```bash
  mix kiln.search.measure_floor golden.json
  mix kiln.search.measure_floor golden.json --type herb --limit 50
  mix kiln.search.measure_floor golden.json --org acme --locale fr
  ```

  ## The golden set

  The same file `mix kiln.search.eval` reads (`KilnCMS.Search.Eval.parse/1`):
  a JSON array of rows with a `query`, the `expected` slugs, a `class`, and
  optionally the `type` and `locale` the row is about. A `junk` row expects
  nothing — the gibberish that gave #871 its 149 constant rows, or a
  paraphrase of something the corpus does not cover. One set serves both
  tasks, so a slug renamed for one is renamed for the other, and the bands
  below come out per class.

  ```json
  [
    {"query": "huang qi", "expected": ["huang-qi"], "class": "single_entity", "type": "herb"},
    {"query": "huang qi dang shen", "expected": ["huang-qi", "dang-shen"],
     "class": "multi_entity", "type": "herb"},
    {"query": "herb that strengthens defensive energy", "expected": ["huang-qi"],
     "class": "paraphrase"},
    {"query": "asdfghjkl zzqqxx", "expected": [], "class": "junk"}
  ]
  ```

  Give a row a `type` when its slug exists in more than one content type —
  slugs are unique only within a type — and a `locale` when the row is not
  about the default locale. Mix the classes the floor has to serve: a set of
  only exact titles measures the easy band and nothing else.

  ## The report

  For each query, the nearest `--limit` rows of every content type (or the
  one named by `--type`, or the row's own `type`), measured by **the semantic
  leg hybrid search runs**: `KilnCMS.Search.semantic_neighbours/3` runs the
  `:search_semantic_published` action under the same context `hybrid/3` uses,
  so it sees the query's locale, embedded rows, and published rows only —
  and ignores any floor already configured, because you cannot tune a
  threshold that has already been applied. Each expected record is reported
  with its distance, its rank within its type and the nearest record that is
  *not* one the row expects; a junk query with its nearest neighbour. An
  expected record outside the nearest `--limit` is looked up directly so its
  distance is still measured.

  The two bands — how far the expected records sit, how near the junk gets —
  give the suggestion, overall and per class. When they are separable the
  midpoint is proposed; when they overlap, the task says which queries
  overlap and what each edge would keep and admit, because that is a choice
  about which error to make (or a sign the corpus wants reranking, not a
  floor).

  Set the result in config:

  ```elixir
  config :kiln_cms, KilnCMS.Search, semantic_max_distance: 0.5
  ```

  The two surfaces the value governs want different edges, and the report
  labels both. `KilnCMS.Search.hybrid/3` applies the floor to semantic-only
  hits after fusion — a record any other leg (keyword, its any-term
  relaxation, title or fuzzy) also returns is never floored — so for the
  search page, `/api/search` and `/api/ask` the number to set is where the
  junk band starts. The per-type `semantic-search` API routes have no other
  leg and floor the whole leg, so they return every expected record only
  from the furthest expected distance up. A floor between the two keeps
  hybrid clean and drops the hardest expected records from the per-type
  routes; the report says which.

  Reads run against one tenant — `--org` (a slug) or, absent, the default
  organization — through the published-only action with no actor, the way
  an anonymous `/api/search` reads.
  """
  @shortdoc "Measure where to set semantic_max_distance for this corpus"

  use Mix.Task

  # `Ash.Query.filter/2` is a macro — for scoping `Entry` to one dynamic type.
  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search
  alias KilnCMS.Search.Eval

  @requirements ["app.start"]

  @switches [type: :string, org: :string, limit: :integer, locale: :string]

  @impl Mix.Task
  def run(args) do
    {opts, files, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Unknown option(s): " <> Enum.map_join(invalid, ", ", &elem(&1, 0)))
    end

    path =
      case files do
        [path] ->
          path

        _ ->
          Mix.raise(
            "Usage: mix kiln.search.measure_floor GOLDEN_SET.json " <>
              "[--type T] [--org SLUG] [--locale L] [--limit N]"
          )
      end

    unless Search.semantic?() do
      Mix.raise("""
      Semantic search is disabled, so there is nothing to measure.

      Enable it (`config :kiln_cms, KilnCMS.Search, semantic: true`) and make
      sure the corpus is embedded first.
      """)
    end

    rows = read_golden_set(path)
    limit = Keyword.get(opts, :limit, 20)
    tenant = resolve_org(Keyword.get(opts, :org))
    locale = Keyword.get(opts, :locale) || KilnCMS.I18n.default_locale()
    read_opts = [authorize?: true, tenant: tenant, published: true]
    targets = targets(Keyword.get(opts, :type), tenant)

    shell = Mix.shell()

    shell.info(
      "Semantic floor measurement — #{length(rows)} queries x " <>
        "#{length(targets)} content type(s), #{limit} neighbours each"
    )

    shell.info(
      "tenant: #{tenant}   locale: #{locale}   embedder: #{inspect(Search.embedder())}   " <>
        "configured floor: #{inspect(Search.semantic_max_distance())} (ignored here)\n"
    )

    results = Enum.map(rows, &measure(&1, targets, locale, read_opts, limit))

    Enum.each(results, &shell.info(render(&1)))
    shell.info(suggestion(results))
  end

  # --- the golden set --------------------------------------------------------

  # The eval task's reader, and the eval harness's parser: one format, one
  # validator, one set of error messages naming the offending row.
  defp read_golden_set(path) do
    with {:ok, json} <- File.read(path),
         {:ok, rows} <- Eval.parse(json) do
      rows
    else
      {:error, reason} when is_atom(reason) ->
        Mix.raise("Cannot read #{path}: #{:file.format_error(reason)}")

      {:error, message} ->
        Mix.raise("#{path}: #{message}")
    end
  end

  defp resolve_org(nil), do: KilnCMS.Accounts.default_org_id()

  defp resolve_org(slug) do
    # Operator-run task resolving the org it was told to measure — the
    # organization registry has no anonymous read, and this is not a request.
    case KilnCMS.Accounts.get_organization_by_slug(slug, authorize?: false) do
      {:ok, %{id: id}} -> id
      _none -> Mix.raise("no organization with slug #{inspect(slug)}")
    end
  end

  # --- what to measure against -----------------------------------------------

  # One target per content type: `{type name, section plural, base}` where the
  # base is what `Search.semantic_neighbours/3` measures — the compiled type's
  # resource, or `Entry` scoped to one dynamic type's definition. Slugs are
  # unique only within a type (and `Entry` holds every dynamic type in one
  # table), so a target is never wider than a type, and every row is labelled
  # with the type it belongs to.
  defp targets(nil, tenant) do
    compiled = Enum.map(ContentTypes.all(), &target/1)
    dynamic = tenant |> ContentTypes.dynamic_all() |> Enum.map(&target/1)
    compiled ++ dynamic
  end

  defp targets(type, tenant) do
    case ContentTypes.get(type, tenant) do
      nil ->
        known =
          targets(nil, tenant)
          |> Enum.map(&elem(&1, 0))
          |> Enum.join(", ")

        Mix.raise("Unknown content type #{inspect(type)}. Known: #{known}")

      descriptor ->
        [target(descriptor)]
    end
  end

  defp target(%{source: :dynamic, type: name, definition: definition}) do
    base =
      KilnCMS.CMS.Entry
      |> Ash.Query.new()
      |> Ash.Query.filter(type_definition_id == ^definition.id)

    {to_string(name), "entries", base}
  end

  defp target(%{type: type, section: section, resource: resource}) do
    {to_string(type), to_string(section), resource}
  end

  # A row's `type` narrows the targets the way `KilnCMS.Search.Eval.judge/2`
  # narrows hits: by type name or section plural.
  defp targets_for(targets, nil), do: targets

  defp targets_for(targets, wanted) do
    case Enum.filter(targets, fn {type, section, _base} -> wanted in [type, section] end) do
      [] -> Mix.raise("A row names type #{inspect(wanted)}, which is not being measured.")
      narrowed -> narrowed
    end
  end

  # --- one query -------------------------------------------------------------

  defp measure(%{query: query} = row, targets, locale, read_opts, limit) do
    case Search.embed_query(query) do
      {:ok, vector} ->
        targets = targets_for(targets, row.type)
        opts = [query_vector: vector, locale: row.locale || locale] ++ read_opts
        neighbours = neighbours(targets, query, [limit: limit] ++ opts)
        judge(row, neighbours, targets, opts)

      {:error, reason} ->
        Map.put(row, :error, reason)
    end
  end

  # Every target's nearest rows, tagged with the type, merged nearest first.
  # Rank is per type — the rank the hybrid search's semantic leg gives, since
  # `semantic_neighbours/3` runs that leg.
  defp neighbours(targets, query, opts) do
    targets
    |> Enum.flat_map(fn {type, _section, base} -> type_neighbours(type, base, query, opts) end)
    |> Enum.sort_by(& &1.distance)
  end

  defp type_neighbours(type, base, query, opts) do
    case Search.semantic_neighbours(base, query, opts) do
      {:ok, rows} ->
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, rank} -> row |> Map.put(:type, type) |> Map.put(:rank, rank) end)

      {:error, error} ->
        Mix.raise("Reading #{type} failed: #{Exception.message(error)}")
    end
  end

  # A junk query: its nearest row is the whole story.
  defp judge(%{expected: []} = row, neighbours, _targets, _opts) do
    Map.put(row, :nearest, List.first(neighbours))
  end

  defp judge(%{expected: slugs} = row, neighbours, targets, opts) do
    hits =
      Enum.map(slugs, fn slug ->
        {slug,
         Enum.find(neighbours, &(&1.slug == slug)) || lookup(targets, row.query, slug, opts)}
      end)

    # The nearest record the row does NOT expect: for a multi-entity row the
    # other expected record is not a competitor, it is the other answer.
    competitor = Enum.find(neighbours, &(&1.slug not in slugs))

    row
    |> Map.put(:hits, hits)
    |> Map.put(:competitor, competitor)
  end

  # The expected record sits beyond the nearest `limit` of every target: read
  # it by slug so the report still carries its distance (and says how far out
  # it is), rather than reporting only that it was not near.
  defp lookup(targets, query, slug, opts) do
    Enum.find_value(targets, fn {type, _section, base} ->
      case Search.semantic_neighbours(base, query, [slug: slug, limit: 1] ++ opts) do
        {:ok, [row]} -> row |> Map.put(:type, type) |> Map.put(:rank, nil)
        {:ok, []} -> nil
        {:error, error} -> Mix.raise("Reading #{type} failed: #{Exception.message(error)}")
      end
    end)
  end

  # --- the report ------------------------------------------------------------

  defp render(%{error: reason, query: query}) do
    ~s|"#{query}"\n  could not be embedded: #{inspect(reason)}\n|
  end

  defp render(%{expected: [], query: query, class: class, nearest: nearest}) do
    ~s|"#{query}"  [#{class}]  → expects nothing\n  nearest    #{row(nearest)}\n|
  end

  defp render(%{query: query, class: class, expected: slugs, hits: hits, competitor: competitor}) do
    header = ~s|"#{query}"  [#{class}]  → expects #{Enum.join(slugs, ", ")}\n|

    expected_lines =
      Enum.map_join(hits, fn
        {slug, nil} ->
          "  expected   NOT FOUND — no #{slug} in any measured type, or it has no " <>
            "embedding, or it is not published in this locale\n"

        {_slug, hit} ->
          "  expected   #{row(hit)}   (#{rank(hit)})\n"
      end)

    header <> expected_lines <> "  nearest ≠  #{row(competitor)}\n"
  end

  defp rank(%{rank: nil}), do: "beyond the nearest rows of its type"
  defp rank(%{rank: n}), do: "rank #{n} of its type"

  defp row(nil), do: "(none)"

  defp row(%{type: type, slug: slug, distance: distance}) do
    String.pad_trailing(type, 8) <> " " <> String.pad_trailing(slug, 32) <> " " <> fmt(distance)
  end

  defp fmt(distance) when is_number(distance),
    do: :erlang.float_to_binary(distance / 1, decimals: 4)

  defp fmt(_other), do: "n/a"

  # --- the suggestion --------------------------------------------------------

  defp suggestion(results) do
    expected =
      for %{hits: hits, class: class, query: query} <- results,
          {_slug, %{distance: d} = hit} <- hits,
          is_number(d),
          do: %{query: query, class: class, slug: hit.slug, distance: d}

    junk =
      for %{expected: [], nearest: %{distance: d} = nearest} = r <- results,
          is_number(d),
          do: %{query: r.query, class: r.class, slug: nearest.slug, distance: d}

    per_class =
      expected
      |> Enum.group_by(& &1.class)
      |> Enum.sort_by(fn {class, _} -> Enum.find_index(Eval.classes(), &(&1 == class)) end)
      |> Enum.map_join(fn {class, rows} -> band("  #{class}", Enum.map(rows, & &1.distance)) end)

    "Bands\n" <>
      band("expected records", Enum.map(expected, & &1.distance)) <>
      per_class <>
      band("junk queries' nearest", Enum.map(junk, & &1.distance)) <>
      "\n" <> advice(expected, junk)
  end

  defp band(name, []), do: "  #{String.pad_trailing(name, 24)} (none in the set)\n"

  defp band(name, distances) do
    "  #{String.pad_trailing(name, 24)} #{fmt(Enum.min(distances))} – " <>
      "#{fmt(Enum.max(distances))}   (n=#{length(distances)})\n"
  end

  defp advice([], []) do
    "Nothing to suggest: no expected record was found and no junk query was given.\n"
  end

  defp advice([], junk) do
    nearest = Enum.min_by(junk, & &1.distance)

    "No expected record was found, so nothing here says what a floor would keep.\n" <>
      "The junk band starts at #{fmt(nearest.distance)} (#{nearest.slug} for " <>
      ~s|"#{nearest.query}"); a floor just below it rejects every junk query.\n|
  end

  defp advice(expected, []) do
    furthest = Enum.max_by(expected, & &1.distance)

    "No junk queries in the set, so nothing here says what a floor would reject.\n" <>
      "Every expected record is within #{fmt(furthest.distance)} (#{furthest.slug} for " <>
      ~s|"#{furthest.query}"); add junk rows to find the other band.\n|
  end

  # Two edges, one per surface. The floor drops a hit whose distance is
  # strictly greater, so a floor AT the furthest expected distance keeps it,
  # and rejecting a junk hit takes a floor strictly below its distance —
  # hence "just below", and `dropped` counted with `>=`.
  defp advice(expected, junk) do
    furthest = Enum.max_by(expected, & &1.distance)
    nearest = Enum.min_by(junk, & &1.distance)

    if furthest.distance < nearest.distance do
      midpoint = (furthest.distance + nearest.distance) / 2

      "Suggested semantic_max_distance: #{fmt(midpoint)}\n" <>
        "  keeps every expected record and rejects every junk query on both surfaces;\n" <>
        "  the gap between the furthest expected record (#{fmt(furthest.distance)}) and\n" <>
        "  the nearest junk neighbour (#{fmt(nearest.distance)}) is " <>
        "#{fmt(nearest.distance - furthest.distance)}.\n" <> surfaces()
    else
      keep_all = furthest.distance
      reject_all = nearest.distance
      admitted = Enum.count(junk, &(&1.distance <= keep_all))
      dropped = Enum.count(expected, &(&1.distance >= reject_all))

      "Suggested semantic_max_distance: no single value separates the bands\n" <>
        "  the furthest expected record (#{furthest.slug} for \"#{furthest.query}\", " <>
        "#{fmt(keep_all)}) sits beyond\n" <>
        "  the nearest junk neighbour (#{nearest.slug} for \"#{nearest.query}\", " <>
        "#{fmt(reject_all)}).\n" <>
        "  #{fmt(keep_all)} keeps every expected record and admits #{admitted} of " <>
        "#{length(junk)} junk queries;\n" <>
        "  just below #{fmt(reject_all)} rejects every junk query and drops #{dropped} of " <>
        "#{length(expected)} expected records.\n" <>
        surfaces() <>
        "  If neither edge is acceptable, the corpus is not separable by distance alone\n" <>
        "  and wants reranking (`rerank: true`).\n"
    end
  end

  defp surfaces do
    "  Hybrid search (the search page, /api/search, /api/ask) floors only hits no\n" <>
      "  other leg returned, so an expected record the keyword, any-term, title or\n" <>
      "  fuzzy leg also finds survives a floor below its distance: set it at the\n" <>
      "  junk edge. The per-type semantic-search routes floor the whole leg, so they\n" <>
      "  return every expected record only from the expected edge up.\n"
  end
end
