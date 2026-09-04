defmodule KilnCMS.Search.Eval do
  @moduledoc """
  Ranking evaluation over a **golden set**: recall@k and MRR per query class,
  plus the per-query ranks that make a regression debuggable. The pure half of
  `mix kiln.search.eval` — everything here is a function of the golden set
  and the ranked hits, so a change to the search stack can be measured before
  and after without a database in the loop, and the metrics themselves are
  unit-tested (and mutation-tested) on their own.

  ## The golden set

  A JSON array of rows (or an object whose `"rows"` or `"queries"` key holds
  one):

      [
        {"query": "huang qi", "expected": ["huang-qi"], "class": "single_entity"},
        {"query": "huang qi dang shen", "expected": ["huang-qi", "dang-shen"],
         "class": "multi_entity", "type": "herb"},
        {"query": "asdfghjkl zzqqxx", "expected": [], "class": "junk"}
      ]

    * `query` — what a user typed.
    * `expected` — the slugs that should come back, in no particular order.
      Empty **only** for `junk`, which passes only when *nothing* is returned.
    * `class` — one of #{inspect(~w(single_entity multi_entity paraphrase question_form typo junk))}.
      Kept as strings end to end: a golden set is operator input, and a class
      name never becomes an atom.
    * `type` (optional) — a content type name (`page`, `post`, a dynamic type's
      name) or a section plural (`pages`, `herbs`); ranks are then taken
      within that type only.
    * `locale` (optional) — the content locale to search in.

  ## The metrics

  Every query is judged on one ranked list of slugs (see
  `KilnCMS.Search.Eval.Retriever` for how the sections become one list).

    * **recall@k** — the fraction of `expected` slugs ranked at or above `k`.
      A row naming two slugs with one at rank 2 and one at rank 7 scores 0.5
      at k = 5 and 1.0 at k = 10.
    * **reciprocal rank** — 1 / (best rank of any expected slug), 0 when none
      surfaced. **MRR** is its mean over the rows.
    * **junk** rows have no expected slugs, so both metrics reduce to pass or
      fail: 1.0 when nothing came back, 0.0 otherwise — at every `k`, since
      a nonsense query that returns anything at rank 12 is as wrong as one
      that returns it at rank 1.

  Class and overall figures are **macro-averages** over their rows, so a
  class with two queries weighs the same per query as one with ten, and the
  overall line is the mean over every row (junk included, as pass/fail).
  """

  @classes ~w(single_entity multi_entity paraphrase question_form typo junk)
  @default_ks [1, 3, 5, 10]

  @typedoc "One golden-set row, validated."
  @type row :: %{
          query: String.t(),
          expected: [String.t()],
          class: String.t(),
          type: String.t() | nil,
          locale: String.t() | nil
        }

  @typedoc """
  One ranked hit, as a retriever hands it over: the slug, the content type
  name and section plural it came from (either may be `nil` for a source
  that does not report it), the score it was ranked by, and the legs that
  found it (strings — `"keyword"`, `"semantic"`, `"fuzzy"`).
  """
  @type hit :: %{
          slug: String.t(),
          type: String.t() | nil,
          section: String.t() | nil,
          score: float() | nil,
          legs: [String.t()]
        }

  @typedoc "One expected slug after judging: where it landed, and which legs found it."
  @type placement :: %{slug: String.t(), rank: pos_integer() | nil, legs: [String.t()]}

  @typedoc "A row judged against its hits."
  @type judged :: %{
          query: String.t(),
          class: String.t(),
          type: String.t() | nil,
          locale: String.t() | nil,
          expected: [placement()],
          returned: non_neg_integer(),
          returned_slugs: [String.t()]
        }

  @typedoc "Macro-averaged figures for a class (or the whole set)."
  @type stats :: %{
          queries: non_neg_integer(),
          recall: %{pos_integer() => float()},
          mrr: float()
        }

  @typedoc "A `--fail-below` threshold: `class` is a class name or `\"overall\"`."
  @type threshold :: %{class: String.t(), k: pos_integer(), min: float()}

  @doc "The query classes a golden set may use, in report order."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @doc "The `k` values reported when none are asked for."
  @spec default_ks() :: [pos_integer()]
  def default_ks, do: @default_ks

  # --- the golden set --------------------------------------------------------

  @doc """
  Decodes and validates a golden set from its JSON text.

  Every problem names the offending row (0-based) and field, because the
  file is hand-written and "invalid golden set" on its own sends the author
  back to squint at thirty rows.
  """
  @spec parse(binary()) :: {:ok, [row()]} | {:error, String.t()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> rows(decoded)
      {:error, %Jason.DecodeError{} = error} -> {:error, Jason.DecodeError.message(error)}
    end
  end

  defp rows(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case row(raw, index) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "the golden set has no rows"}
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp rows(%{"rows" => list}) when is_list(list), do: rows(list)
  defp rows(%{"queries" => list}) when is_list(list), do: rows(list)

  defp rows(_other),
    do: {:error, "expected a JSON array of rows (or an object with a \"rows\" array)"}

  defp row(raw, index) when is_map(raw) do
    with {:ok, query} <- string_field(raw, "query", index),
         {:ok, class} <- class_field(raw, index),
         {:ok, expected} <- expected_field(raw, class, index),
         {:ok, type} <- optional_string_field(raw, "type", index),
         {:ok, locale} <- optional_string_field(raw, "locale", index) do
      {:ok, %{query: query, expected: expected, class: class, type: type, locale: locale}}
    end
  end

  defp row(_raw, index), do: {:error, "row #{index}: expected an object"}

  defp string_field(raw, key, index) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "row #{index}: \"#{key}\" is blank"}
          trimmed -> {:ok, trimmed}
        end

      _missing ->
        {:error, "row #{index}: \"#{key}\" must be a string"}
    end
  end

  defp optional_string_field(raw, key, index) do
    case Map.get(raw, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "row #{index}: \"#{key}\" must be a non-empty string when present"}
    end
  end

  defp class_field(raw, index) do
    case Map.get(raw, "class") do
      class when class in @classes ->
        {:ok, class}

      _other ->
        {:error, "row #{index}: \"class\" must be one of #{Enum.join(@classes, ", ")}"}
    end
  end

  # `expected` is required, and its emptiness is tied to the class in both
  # directions: a junk row with slugs is a contradiction (it cannot both
  # expect nothing and expect something), and a non-junk row with none would
  # score 0 forever and quietly drag the class average down.
  defp expected_field(raw, class, index) do
    case Map.get(raw, "expected") do
      list when is_list(list) ->
        cond do
          not Enum.all?(list, &(is_binary(&1) and &1 != "")) ->
            {:error, "row #{index}: \"expected\" must be a list of non-empty slugs"}

          class == "junk" and list != [] ->
            {:error, "row #{index}: a junk row must expect nothing (\"expected\": [])"}

          class != "junk" and list == [] ->
            {:error, "row #{index}: a #{class} row must expect at least one slug"}

          true ->
            {:ok, Enum.uniq(list)}
        end

      _other ->
        {:error, "row #{index}: \"expected\" must be a list of slugs"}
    end
  end

  # --- judging ---------------------------------------------------------------

  @doc """
  Judges one row against the ranked hits a retriever returned for it.

  A row's `type` narrows the hits to that content type (by type name or
  section plural) before ranks are assigned, so "rank 3 among herbs" is what
  a typed row measures. Hits are deduplicated by slug, first occurrence
  winning — two content types can share a slug, and a sectioned search can
  return the same record twice only by mistake, but a rank must be a
  position in *one* list.
  """
  @spec judge(row(), [hit()]) :: judged()
  def judge(row, hits) do
    ranked =
      hits
      |> Enum.filter(&type_matches?(&1, row.type))
      |> Enum.uniq_by(& &1.slug)

    expected =
      Enum.map(row.expected, fn slug ->
        case Enum.find_index(ranked, &(&1.slug == slug)) do
          nil -> %{slug: slug, rank: nil, legs: []}
          index -> %{slug: slug, rank: index + 1, legs: Enum.at(ranked, index).legs}
        end
      end)

    %{
      query: row.query,
      class: row.class,
      type: row.type,
      locale: row.locale,
      expected: expected,
      returned: length(ranked),
      returned_slugs: Enum.map(ranked, & &1.slug)
    }
  end

  defp type_matches?(_hit, nil), do: true
  defp type_matches?(%{type: type, section: section}, wanted), do: wanted in [type, section]

  @doc """
  recall@k for one judged row: the share of its expected slugs ranked at or
  above `k`. A junk row is 1.0 when nothing was returned, else 0.0.
  """
  @spec recall_at(judged(), pos_integer()) :: float()
  def recall_at(%{class: "junk"} = judged, _k), do: junk_score(judged)

  def recall_at(%{expected: expected}, k) when is_integer(k) and k > 0 do
    found = Enum.count(expected, fn %{rank: rank} -> is_integer(rank) and rank <= k end)
    found / length(expected)
  end

  @doc """
  The reciprocal of the best rank any expected slug reached, 0.0 when none
  did. A junk row is 1.0 when nothing was returned, else 0.0.
  """
  @spec reciprocal_rank(judged()) :: float()
  def reciprocal_rank(%{class: "junk"} = judged), do: junk_score(judged)

  def reciprocal_rank(%{expected: expected}) do
    expected
    |> Enum.map(& &1.rank)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      ranks -> 1 / Enum.min(ranks)
    end
  end

  @doc "Whether a junk row passed: nothing came back."
  @spec junk_passed?(judged()) :: boolean()
  def junk_passed?(%{returned: returned}), do: returned == 0

  defp junk_score(judged), do: if(junk_passed?(judged), do: 1.0, else: 0.0)

  # --- aggregation -----------------------------------------------------------

  @doc """
  Macro-averages the judged rows: one `t:stats/0` per class present (keyed by
  class name) and one for the whole set under `:overall`.
  """
  @spec summarize([judged()], [pos_integer()]) :: %{
          overall: stats(),
          classes: %{String.t() => stats()}
        }
  def summarize(judged, ks \\ @default_ks) do
    classes =
      judged
      |> Enum.group_by(& &1.class)
      |> Map.new(fn {class, rows} -> {class, stats(rows, ks)} end)

    %{overall: stats(judged, ks), classes: classes}
  end

  defp stats([], ks), do: %{queries: 0, recall: Map.new(ks, &{&1, 0.0}), mrr: 0.0}

  defp stats(rows, ks) do
    %{
      queries: length(rows),
      recall: Map.new(ks, fn k -> {k, mean(Enum.map(rows, &recall_at(&1, k)))} end),
      mrr: mean(Enum.map(rows, &reciprocal_rank/1))
    }
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  @doc """
  Runs the whole evaluation: judges every row with the hits `retrieve.(row)`
  returns, and assembles the report the task prints and serialises.
  """
  @spec report([row()], (row() -> [hit()]), [pos_integer()]) :: %{
          ks: [pos_integer()],
          queries: [judged()],
          summary: %{overall: stats(), classes: %{String.t() => stats()}}
        }
  def report(rows, retrieve, ks \\ @default_ks) when is_function(retrieve, 1) do
    judged = Enum.map(rows, &judge(&1, retrieve.(&1)))
    %{ks: ks, queries: judged, summary: summarize(judged, ks)}
  end

  # --- thresholds ------------------------------------------------------------

  @doc """
  Parses one `--fail-below` value: `CLASS=MIN` or `CLASS=MIN@K`, where
  `CLASS` is a query class or `overall`, `MIN` is a recall in `0..1`, and
  `K` (default `default_k`) is which recall@k to hold to it.

      iex> parse_threshold("single_entity=0.9@5", 10)
      {:ok, %{class: "single_entity", k: 5, min: 0.9}}
      iex> parse_threshold("overall=0.75", 10)
      {:ok, %{class: "overall", k: 10, min: 0.75}}
      iex> parse_threshold("herbs=0.9", 10)
      {:error, "unknown class \\"herbs\\" in --fail-below herbs=0.9"}
  """
  @spec parse_threshold(String.t(), pos_integer()) :: {:ok, threshold()} | {:error, String.t()}
  def parse_threshold(spec, default_k) when is_binary(spec) do
    with [class, rest] <- String.split(spec, "=", parts: 2),
         true <- class in ["overall" | @classes] || {:error, :class},
         {min, k_part} <- Float.parse(rest),
         true <- (min >= 0.0 and min <= 1.0) || {:error, :min},
         {:ok, k} <- threshold_k(k_part, default_k) do
      {:ok, %{class: class, k: k, min: min}}
    else
      {:error, :class} ->
        [class | _] = String.split(spec, "=", parts: 2)
        {:error, "unknown class #{inspect(class)} in --fail-below #{spec}"}

      _other ->
        {:error,
         "--fail-below expects CLASS=MIN or CLASS=MIN@K (MIN in 0..1, K a positive integer), got: #{spec}"}
    end
  end

  defp threshold_k("", default_k), do: {:ok, default_k}

  defp threshold_k("@" <> k, _default_k) do
    case Integer.parse(k) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> :error
    end
  end

  defp threshold_k(_other, _default_k), do: :error

  @doc """
  The thresholds a summary does not meet. Empty when every one holds — and
  when there are none, which is the default: the report is a report, not a
  gate, until a deployment's baselines settle.

  A threshold on a `k` the report did not compute, or on a class with no
  rows, is itself a failure: silently passing it would make a typo in
  `--fail-below` indistinguishable from a healthy ranking.
  """
  @spec failures(%{overall: stats(), classes: %{String.t() => stats()}}, [threshold()]) ::
          [%{class: String.t(), k: pos_integer(), min: float(), actual: float() | nil}]
  def failures(summary, thresholds) do
    Enum.flat_map(thresholds, fn %{class: class, k: k, min: min} ->
      stats = if class == "overall", do: summary.overall, else: summary.classes[class]

      case stats && Map.get(stats.recall, k) do
        actual when is_float(actual) and actual >= min -> []
        actual -> [%{class: class, k: k, min: min, actual: actual}]
      end
    end)
  end

  # --- rendering -------------------------------------------------------------

  @doc "The report as the terminal table plus one block per query."
  @spec format_text(map(), keyword()) :: String.t()
  def format_text(report, opts \\ []) do
    source = Keyword.get(opts, :source, "global")

    header =
      "Search eval — #{length(report.queries)} queries, source: #{source}, " <>
        "k = #{Enum.join(report.ks, ",")}"

    Enum.join([header, "", summary_table(report), "", "Per query:" | query_lines(report)], "\n")
  end

  defp summary_table(%{ks: ks, summary: summary}) do
    rows = class_rows(summary)
    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 5 end) |> max(5)

    header =
      String.pad_trailing("class", width) <>
        String.pad_leading("queries", 9) <>
        Enum.map_join(ks, "", &String.pad_leading("r@#{&1}", 7)) <>
        String.pad_leading("MRR", 7)

    lines =
      Enum.map(rows, fn {name, stats} ->
        String.pad_trailing(name, width) <>
          String.pad_leading(Integer.to_string(stats.queries), 9) <>
          Enum.map_join(ks, "", &String.pad_leading(fmt(stats.recall[&1]), 7)) <>
          String.pad_leading(fmt(stats.mrr), 7)
      end)

    Enum.join([header | lines], "\n")
  end

  # Classes in their canonical order, only those with rows, then the total.
  defp class_rows(summary) do
    present = Enum.filter(@classes, &Map.has_key?(summary.classes, &1))
    Enum.map(present, &{&1, summary.classes[&1]}) ++ [{"overall", summary.overall}]
  end

  defp query_lines(%{queries: queries}) do
    Enum.flat_map(queries, fn judged ->
      label = "[#{judged.class}] #{inspect(judged.query)}" <> type_suffix(judged)

      if judged.class == "junk" do
        [label <> "  " <> junk_verdict(judged)]
      else
        width = judged.expected |> Enum.map(&String.length(&1.slug)) |> Enum.max()

        [label | Enum.map(judged.expected, &placement_line(&1, width))]
      end
    end)
  end

  defp type_suffix(%{type: nil}), do: ""
  defp type_suffix(%{type: type}), do: " (type: #{type})"

  defp junk_verdict(judged) do
    if junk_passed?(judged) do
      "PASS  (0 returned)"
    else
      "FAIL  (#{judged.returned} returned: #{sample(judged.returned_slugs)})"
    end
  end

  defp sample(slugs) do
    shown = Enum.take(slugs, 3)
    rest = length(slugs) - length(shown)
    Enum.join(shown, ", ") <> if(rest > 0, do: ", … +#{rest}", else: "")
  end

  defp placement_line(%{slug: slug, rank: nil}, width),
    do: "    " <> String.pad_trailing(slug, width) <> "  missing"

  defp placement_line(%{slug: slug, rank: rank, legs: legs}, width) do
    "    " <>
      String.pad_trailing(slug, width) <>
      "  " <> String.pad_leading("#" <> Integer.to_string(rank), 4) <> "  " <> legs_label(legs)
  end

  defp legs_label([]), do: "(no legs reported)"
  defp legs_label(legs), do: Enum.join(legs, ", ")

  defp fmt(nil), do: "—"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  @doc """
  The summary table as Markdown — appended to the GitHub job summary when the
  task runs under Actions, the way `mix kiln.coverage.summary` is.
  """
  @spec format_markdown(map(), keyword()) :: String.t()
  def format_markdown(report, opts \\ []) do
    source = Keyword.get(opts, :source, "global")
    ks = report.ks

    body =
      report.summary
      |> class_rows()
      |> Enum.map_join("\n", fn {name, stats} ->
        label = if name == "overall", do: "**overall**", else: "`#{name}`"

        "| #{label} | #{stats.queries} | " <>
          Enum.map_join(ks, " | ", &fmt(stats.recall[&1])) <> " | #{fmt(stats.mrr)} |"
      end)

    missing =
      report.queries
      |> Enum.reject(&(&1.class == "junk"))
      |> Enum.flat_map(fn judged ->
        judged.expected
        |> Enum.filter(&is_nil(&1.rank))
        |> Enum.map(&"- `#{judged.query}` → `#{&1.slug}` missing")
      end)

    failed_junk =
      report.queries
      |> Enum.filter(&(&1.class == "junk" and not junk_passed?(&1)))
      |> Enum.map(&"- `#{&1.query}` returned #{&1.returned} (junk should return nothing)")

    """
    ### Search ranking eval (#{source}, #{length(report.queries)} queries)

    | class | queries | #{Enum.map_join(ks, " | ", &"r@#{&1}")} | MRR |
    | --- | ---: | #{Enum.map_join(ks, " | ", fn _ -> "---:" end)} | ---: |
    #{body}
    #{misses_section(missing ++ failed_junk)}
    """
  end

  defp misses_section([]), do: ""
  defp misses_section(lines), do: "\n**Misses**\n\n" <> Enum.join(lines, "\n") <> "\n"

  @doc """
  The report as a JSON-ready map — `--json` output. Integer keys become
  strings (`"recall": {"1": 1.0, …}`) and the per-query lines keep the ranks
  and legs, so two runs diff cleanly before and after a change.
  """
  @spec to_json_map(map(), keyword()) :: map()
  def to_json_map(report, opts \\ []) do
    %{
      source: Keyword.get(opts, :source, "global"),
      ks: report.ks,
      summary: %{
        overall: json_stats(report.summary.overall),
        classes:
          Map.new(report.summary.classes, fn {class, stats} -> {class, json_stats(stats)} end)
      },
      queries:
        Enum.map(report.queries, fn judged ->
          %{
            query: judged.query,
            class: judged.class,
            type: judged.type,
            locale: judged.locale,
            returned: judged.returned,
            expected: judged.expected,
            recall: Map.new(report.ks, &{Integer.to_string(&1), recall_at(judged, &1)}),
            reciprocal_rank: reciprocal_rank(judged)
          }
        end)
    }
  end

  defp json_stats(stats) do
    %{
      queries: stats.queries,
      recall: Map.new(stats.recall, fn {k, v} -> {Integer.to_string(k), v} end),
      mrr: stats.mrr
    }
  end
end
