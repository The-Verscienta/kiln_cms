defmodule Mix.Tasks.Kiln.Search.MeasureFloor do
  @moduledoc """
  Measures where `semantic_max_distance` should sit for **this** corpus and
  embedder, from a sheet of queries.

  `KilnCMS.Search.semantic_max_distance/0` ships as `nil` because the useful
  cutoff is a property of the model and the corpus: a number measured on a
  sample drifts as the corpus grows around it, and one measured for one
  embedder can silently empty another. The config comment tells operators to
  measure; this is the measurement.

  ```bash
  mix kiln.search.measure_floor queries.tsv
  mix kiln.search.measure_floor queries.tsv --type herb --limit 50
  mix kiln.search.measure_floor queries.tsv --org 019...   # a specific tenant
  ```

  ## The sheet

  One query per line. A query that should find a record names it by slug
  after a tab; a bare line is a query that should find **nothing** — the junk
  that gave #871 its 149 constant rows, or a paraphrase of something the
  corpus does not cover. Blank lines and `#` comments are skipped.

  ```text
  # entity names, name pairs, paraphrases, junk
  huang qi<TAB>huang-qi
  huang qi dang shen<TAB>huang-qi
  herb that strengthens defensive energy<TAB>huang-qi
  asdfghjkl zzqqxx
  ```

  Mix the classes the floor has to serve: single names, name lists,
  paraphrases, question forms and junk. A sheet of only exact titles measures
  the easy band and nothing else.

  ## The report

  For each query, the nearest `--limit` rows of every content type (or the
  one named by `--type`) by raw cosine distance, ignoring any floor already
  configured — you cannot tune a threshold that has already been applied. An
  expected record is reported with its distance, its rank within its type and
  the nearest record that is *not* it; a junk query with its nearest
  neighbour. An expected record outside the nearest `--limit` is looked up
  directly so its distance is still measured.

  The two bands — how far the expected records sit, how near the junk gets —
  give the suggestion. When they are separable the midpoint is proposed;
  when they overlap, the task says which queries overlap and what each edge
  of the overlap would keep and admit, because that is a choice about which
  error to make (or a sign the corpus wants reranking, not a floor).

  Set the result in config:

  ```elixir
  config :kiln_cms, KilnCMS.Search, semantic_max_distance: 0.5
  ```

  `KilnCMS.Search.hybrid/3` applies the floor to semantic-only hits after
  fusion — a record the keyword or fuzzy leg also returns is never floored —
  so the number to set is where the junk band starts, not where the hardest
  expected record sits. The per-type `semantic-search` API routes still
  filter the whole leg, so an expected record beyond the floor stays reachable
  through hybrid search but not through them.

  Reads run as the system (`authorize?: false`) against one tenant: `--org`
  or, absent, the default organization.
  """
  @shortdoc "Measure where to set semantic_max_distance for this corpus"

  use Mix.Task

  # `Ash.Query.filter/2` is a macro — for the direct slug lookup.
  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search

  @requirements ["app.start"]

  @switches [type: :string, org: :string, limit: :integer]

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
            "Usage: mix kiln.search.measure_floor QUERIES_FILE [--type T] [--org ID] [--limit N]"
          )
      end

    unless Search.semantic?() do
      Mix.raise("""
      Semantic search is disabled, so there is nothing to measure.

      Enable it (`config :kiln_cms, KilnCMS.Search, semantic: true`) and make
      sure the corpus is embedded first.
      """)
    end

    sheet = parse_sheet(path)
    limit = Keyword.get(opts, :limit, 20)
    tenant = Keyword.get(opts, :org) || KilnCMS.Accounts.default_org_id()
    read_opts = [authorize?: false, tenant: tenant]
    resources = resources(Keyword.get(opts, :type), tenant)

    shell = Mix.shell()

    shell.info(
      "Semantic floor measurement — #{length(sheet)} queries x " <>
        "#{length(resources)} content type(s), #{limit} neighbours each"
    )

    shell.info(
      "tenant: #{tenant}   embedder: #{inspect(Search.embedder())}   " <>
        "configured floor: #{inspect(Search.semantic_max_distance())} (ignored here)\n"
    )

    results = Enum.map(sheet, &measure(&1, resources, read_opts, limit))

    Enum.each(results, &shell.info(render(&1)))
    shell.info(suggestion(results))
  end

  # --- the sheet ---------------------------------------------------------

  defp parse_sheet(path) do
    lines =
      case File.read(path) do
        {:ok, text} -> String.split(text, ~r/\r?\n/)
        {:error, reason} -> Mix.raise("Cannot read #{path}: #{:file.format_error(reason)}")
      end

    rows =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.map(fn line ->
        case String.split(line, "\t", parts: 2) do
          [query, expected] -> %{query: String.trim(query), expected: String.trim(expected)}
          [query] -> %{query: query, expected: nil}
        end
      end)
      |> Enum.reject(&(&1.query == ""))

    if rows == [] do
      Mix.raise("#{path} holds no queries (one per line, `query<TAB>expected-slug` for a hit).")
    end

    rows
  end

  # --- what to measure against -------------------------------------------

  defp resources(nil, _tenant) do
    Enum.map(Search.content_resources(), &{label(&1), &1})
  end

  defp resources(type, tenant) do
    case ContentTypes.get(type, tenant) do
      %{source: :dynamic} ->
        [{type, KilnCMS.CMS.Entry}]

      %{resource: resource} when not is_nil(resource) ->
        [{label(resource), resource}]

      _ ->
        Mix.raise(
          "Unknown content type #{inspect(type)}. Known: " <>
            Enum.map_join(Search.content_resources(), ", ", &label/1)
        )
    end
  end

  defp label(KilnCMS.CMS.Entry), do: "entry"
  defp label(resource), do: ContentTypes.type_name(resource) || inspect(resource)

  # --- one query -----------------------------------------------------------

  defp measure(%{query: query} = row, resources, read_opts, limit) do
    case Search.embed_query(query) do
      {:ok, vector} ->
        neighbours = neighbours(resources, query, vector, read_opts, limit)
        judge(row, neighbours, resources, vector, read_opts)

      {:error, reason} ->
        Map.put(row, :error, reason)
    end
  end

  # Every type's nearest rows, tagged with the type, merged nearest first.
  # Rank is per type — the rank the hybrid search's semantic leg would give.
  defp neighbours(resources, query, vector, read_opts, limit) do
    opts = [query_vector: vector, limit: limit] ++ read_opts

    resources
    |> Enum.flat_map(fn {type, resource} -> type_neighbours(type, resource, query, opts) end)
    |> Enum.sort_by(& &1.distance)
  end

  defp type_neighbours(type, resource, query, opts) do
    case Search.semantic_neighbours(resource, query, opts) do
      {:ok, rows} ->
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, rank} -> row |> Map.put(:type, type) |> Map.put(:rank, rank) end)

      {:error, error} ->
        Mix.raise("Reading #{type} failed: #{Exception.message(error)}")
    end
  end

  # A junk query: its nearest row is the whole story.
  defp judge(%{expected: nil} = row, neighbours, _resources, _vector, _read_opts) do
    Map.put(row, :nearest, List.first(neighbours))
  end

  defp judge(%{expected: slug} = row, neighbours, resources, vector, read_opts) do
    expected =
      Enum.find(neighbours, &(&1.slug == slug)) || lookup(resources, slug, vector, read_opts)

    competitor = Enum.find(neighbours, &(&1.slug != slug))

    row
    |> Map.put(:hit, expected)
    |> Map.put(:competitor, competitor)
  end

  # The expected record sits beyond the nearest `limit` of every type: read it
  # by slug so the report still carries its distance (and says how far out
  # it is), rather than reporting only that it was not near.
  defp lookup(resources, slug, vector, read_opts) do
    Enum.find_value(resources, fn {type, resource} ->
      resource
      |> Ash.Query.new()
      |> Ash.Query.filter(slug == ^slug and not is_nil(embedding))
      |> Ash.Query.load(semantic_distance: %{query_vector: vector})
      |> Ash.Query.limit(1)
      |> Ash.read!(read_opts)
      |> case do
        [record] ->
          %{
            id: record.id,
            slug: record.slug,
            title: record.title,
            distance: record.semantic_distance,
            type: type,
            rank: nil
          }

        [] ->
          nil
      end
    end)
  end

  # --- the report ----------------------------------------------------------

  defp render(%{error: reason, query: query}) do
    ~s|"#{query}"\n  could not be embedded: #{inspect(reason)}\n|
  end

  defp render(%{expected: nil, query: query, nearest: nil}) do
    ~s|"#{query}"  → expects nothing\n  nearest    (no embedded rows)\n|
  end

  defp render(%{expected: nil, query: query, nearest: nearest}) do
    ~s|"#{query}"  → expects nothing\n  nearest    #{row(nearest)}\n|
  end

  defp render(%{expected: slug, query: query, hit: nil}) do
    ~s|"#{query}"  → expects #{slug}\n| <>
      "  expected   NOT FOUND — no #{slug} in any measured type, or it has no embedding\n"
  end

  defp render(%{query: query, expected: slug, hit: hit, competitor: competitor}) do
    rank =
      case hit.rank do
        nil -> "beyond the nearest rows of its type"
        n -> "rank #{n} of its type"
      end

    competitor_line =
      case competitor do
        nil -> "  nearest ≠  (none)\n"
        c -> "  nearest ≠  #{row(c)}\n"
      end

    ~s|"#{query}"  → expects #{slug}\n| <>
      "  expected   #{row(hit)}   (#{rank})\n" <> competitor_line
  end

  defp row(%{type: type, slug: slug, distance: distance}) do
    String.pad_trailing(type, 8) <> " " <> String.pad_trailing(slug, 32) <> " " <> fmt(distance)
  end

  defp fmt(distance) when is_number(distance),
    do: :erlang.float_to_binary(distance / 1, decimals: 4)

  defp fmt(_other), do: "n/a"

  # --- the suggestion ------------------------------------------------------

  defp suggestion(results) do
    expected =
      for %{expected: slug, hit: %{distance: d} = hit} = r <- results,
          not is_nil(slug) and is_number(d),
          do: %{query: r.query, slug: hit.slug, distance: d}

    junk =
      for %{expected: nil, nearest: %{distance: d} = nearest} = r <- results,
          is_number(d),
          do: %{query: r.query, slug: nearest.slug, distance: d}

    bands =
      "Bands\n" <>
        band("expected records", Enum.map(expected, & &1.distance)) <>
        band("junk queries' nearest", Enum.map(junk, & &1.distance)) <> "\n"

    bands <> advice(expected, junk)
  end

  defp band(name, []), do: "  #{String.pad_trailing(name, 24)} (none in the sheet)\n"

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
      ~s|"#{nearest.query}"); a floor below it rejects every junk query.\n|
  end

  defp advice(expected, []) do
    furthest = Enum.max_by(expected, & &1.distance)

    "No junk queries in the sheet, so nothing here says what a floor would reject.\n" <>
      "Every expected record is within #{fmt(furthest.distance)} (#{furthest.slug} for " <>
      ~s|"#{furthest.query}"); add bare lines of junk to find the other band.\n|
  end

  defp advice(expected, junk) do
    furthest = Enum.max_by(expected, & &1.distance)
    nearest = Enum.min_by(junk, & &1.distance)

    if furthest.distance < nearest.distance do
      midpoint = (furthest.distance + nearest.distance) / 2

      "Suggested semantic_max_distance: #{fmt(midpoint)}\n" <>
        "  keeps every expected record and rejects every junk query; the gap between\n" <>
        "  the furthest expected record (#{fmt(furthest.distance)}) and the nearest junk\n" <>
        "  neighbour (#{fmt(nearest.distance)}) is #{fmt(nearest.distance - furthest.distance)}.\n" <>
        "  A hit the keyword or fuzzy leg also returns is never floored by hybrid search,\n" <>
        "  so if the gap is thin, favour the junk edge.\n"
    else
      keep_all = furthest.distance
      reject_all = nearest.distance
      admitted = Enum.count(junk, &(&1.distance <= keep_all))
      dropped = Enum.count(expected, &(&1.distance > reject_all))

      "Suggested semantic_max_distance: no single value separates the bands\n" <>
        "  the furthest expected record (#{furthest.slug} for \"#{furthest.query}\", " <>
        "#{fmt(keep_all)}) sits beyond\n" <>
        "  the nearest junk neighbour (#{nearest.slug} for \"#{nearest.query}\", " <>
        "#{fmt(reject_all)}).\n" <>
        "  #{fmt(keep_all)} keeps every expected record and admits #{admitted} of " <>
        "#{length(junk)} junk queries;\n" <>
        "  #{fmt(reject_all)} rejects every junk query and drops #{dropped} of " <>
        "#{length(expected)} expected records.\n" <>
        "  Only semantic-only hits are floored by hybrid search, so an expected record the\n" <>
        "  keyword leg also finds survives either choice. If neither is acceptable, the\n" <>
        "  corpus is not separable by distance alone and wants reranking (`rerank: true`).\n"
    end
  end
end
