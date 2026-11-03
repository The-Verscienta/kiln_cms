defmodule KilnCMS.Search.RankingFixtureTest do
  @moduledoc """
  The adversarial ranking fixture (A10): a synthetic corpus built to trip
  the ranking, a golden set naming what should win
  (`test/support/fixtures/search_ranking/adversarial.json`), and the
  `KilnCMS.Search.Eval` figures for it, so a ranking change comes with a
  number. Before it, the defects below were found by a downstream site
  comparing `/api/search` against Meilisearch.

  The cases, one query class each:

    * `cross_section` — the #2175 lone-record effect. Twenty-five pages match
      both words of "heat interior"; the only post matches one. Ranked per
      section, the post took rank 1 in every leg that returned it and
      outscored some of the pages. Recall@25 over the pages is 1.0 only when
      every one of them ranks above the post.
    * `exact_phrase` — a ~10,000-word document scattering "yellow",
      "emperor", "inner" and "classic" dozens of times each, against a short
      one holding the phrase once.
    * `cjk_name` — a query equal to one record's Chinese name, and a formula
      whose name contains it and whose body repeats it.
    * `typo` / `junk` — a misspelt name that should still be found, and a
      nonsense query that should find nothing.
    * `prefix` — "huang l", the last term half typed.
    * `joined_name` — "huangqi" for "Huang Qi": the words run together.

  **Gates** (`"gates"`, `--fail-below` syntax) fail this test. **Baselines**
  (`"baselines"`) record the classes the engine does not pass yet: a moved
  figure is reported — a notice on the pull request under GitHub Actions —
  but does not fail, so a fix shows up as a number to raise the baseline to,
  and a regression as one to explain. Promote a class to a gate once it
  passes. The report table goes to the job summary as well.

  Semantic search is on, through a bag-of-words embedder: every word hashed
  to one of 384 dimensions, so the semantic, block and tag legs take part,
  deterministically, and "near" means "shares words". With a semantic floor
  configured (0.8), as a deployment that serves junk queries has.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search.Eval
  alias KilnCMS.Search.Eval.Retriever

  @moduletag :capture_log

  @golden Path.expand("../../support/fixtures/search_ranking/adversarial.json", __DIR__)
  @external_resource @golden
  @ks [1, 3, 5, 10, 25]

  defmodule BagOfWordsEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder

    @dim 384

    # The epsilon keeps a text with no words from being the zero vector,
    # whose cosine distance is undefined.
    @impl true
    def embed(text) do
      counts =
        ~r/[\p{L}\p{N}]+/u
        |> Regex.scan(String.downcase(text))
        |> Enum.frequencies_by(fn [word] -> :erlang.phash2(word, @dim) end)

      {:ok, for(i <- 0..(@dim - 1), do: Map.get(counts, i, 0) * 1.0 + 1.0e-6)}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    put_search_env(
      semantic: true,
      embedder: BagOfWordsEmbedder,
      semantic_max_distance: 0.8
    )

    # Exact vector scans, `KilnCMS.Search.VectorScan`'s measurement mode: a
    # gate is a measurement, and the HNSW index is approximate. Its walk
    # also visits the dead entries every earlier test's rolled-back
    # embeddings leave behind, so what it misses depends on which tests ran
    # first. "yellow emperor inner classic" leads by 0.0001 only while both
    # vector legs rank huangdi-neijing first; an HNSW miss in either put it
    # second, on some orders of the ML job's search suite and not others.
    # `SET LOCAL` ends with the test's sandbox transaction, and the sandbox
    # is shared (`async: false`), so every section of the sweep reads
    # through it.
    KilnCMS.Repo.query!("SET LOCAL enable_indexscan = off", [])

    :ok
  end

  defp golden do
    golden = @golden |> File.read!() |> Jason.decode!()
    {:ok, rows} = Eval.parse(Jason.encode!(golden["rows"]))

    gates =
      Enum.map(golden["gates"], fn spec ->
        {:ok, threshold} = Eval.parse_threshold(spec, List.last(@ks))
        threshold
      end)

    %{rows: rows, gates: gates, baselines: golden["baselines"]}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fixture-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(actor, slug, title, body) do
    %{title: title, slug: slug, body_markdown: body}
    |> CMS.create_page!(actor: actor)
    |> then(&CMS.publish_page!(&1, %{}, actor: actor))
  end

  # 10,000 words of filler with the four words of "yellow emperor inner
  # classic" scattered through it — each on its own prime stride, so they
  # recur (over a hundred times between them) but never stand together.
  defp long_canon do
    filler =
      ~w(river stone ledger winter market lantern copper harvest bridge archive
         meadow pottery thread compass orchard harbor quill furnace granary
         tide cedar mortar spindle pasture beacon saddle cistern loom basket)

    0..9_999
    |> Enum.map(fn i ->
      cond do
        rem(i, 97) == 0 -> "yellow"
        rem(i, 89) == 3 -> "emperor"
        rem(i, 83) == 7 -> "inner"
        rem(i, 79) == 11 -> "classic"
        true -> Enum.at(filler, rem(i * 7 + div(i, 13), length(filler)))
      end
    end)
    |> Enum.chunk_every(100)
    |> Enum.map_join("\n\n", &(Enum.join(&1, " ") <> "."))
  end

  # Created in this order every run, so `inserted_at` — the keyword legs'
  # tiebreaker — orders it the same way each time.
  defp seed_corpus do
    actor = admin()

    for n <- 1..25 do
      nn = String.pad_leading("#{n}", 2, "0")

      page(
        actor,
        "heat-pattern-#{nn}",
        "Pattern #{nn}",
        "Heat lodged in the interior, case #{nn}."
      )
    end

    # Pages that match nothing, so the large section is large past its matches.
    for n <- 1..15 do
      nn = String.pad_leading("#{n}", 2, "0")

      page(
        actor,
        "granary-note-#{nn}",
        "Granary note #{nn}",
        "Notes on storing grain, entry #{nn}."
      )
    end

    page(
      actor,
      "huangdi-neijing",
      "Huangdi Neijing",
      "The Yellow Emperor's Inner Classic is the foundational text of the canon."
    )

    page(actor, "canon-field-notes", "Field notes on the old canon", long_canon())

    page(actor, "huang-lian", "Huang Lian 黄连", "Coptis rhizome. Bitter and cold.")

    page(
      actor,
      "huang-lian-jie-du-tang",
      "Huang Lian Jie Du Tang 黄连解毒汤",
      "黄连解毒汤 is built on 黄连: 黄连 leads, with 黄芩, 黄柏 and 栀子."
    )

    page(actor, "huang-qi", "Huang Qi 黄芪", "Astragalus root.")

    page(
      actor,
      "huang-qi-gui-zhi-wu-wu-tang",
      "Huang Qi Gui Zhi Wu Wu Tang 黄芪桂枝五物汤",
      "黄芪桂枝五物汤 is built on 黄芪: 黄芪 leads, with 桂枝, 芍药, 生姜 and 大枣."
    )

    page(actor, "huang-bai", "Huang Bai 黄柏", "Phellodendron bark.")
    page(actor, "lian-qiao", "Lian Qiao 连翘", "Forsythia fruit.")

    # The lone record: the only post, matching one word of "heat interior".
    %{
      title: "Ginseng root",
      slug: "ginseng-root",
      body_markdown: "A measured look at the root and its heat."
    }
    |> CMS.create_post!(actor: actor)
    |> then(&CMS.publish_post!(&1, %{}, actor: actor))

    KilnCMS.DataCase.drain_oban()
  end

  test "every class in the fixture is gated or has a baseline" do
    %{rows: rows, gates: gates, baselines: baselines} = golden()

    accounted = MapSet.new(Enum.map(gates, & &1.class) ++ Map.keys(baselines))
    classes = rows |> MapSet.new(& &1.class)

    assert MapSet.subset?(classes, accounted),
           "classes with neither a gate nor a baseline: " <>
             inspect(MapSet.difference(classes, accounted) |> Enum.sort())

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(gates, & &1.class)),
             MapSet.new(Map.keys(baselines))
           )
  end

  test "the ranking holds its gates on the adversarial corpus" do
    %{rows: rows, gates: gates, baselines: baselines} = golden()
    seed_corpus()

    report = Eval.report(rows, &Retriever.global(&1, limit: 30), @ks)

    with path when is_binary(path) <- System.get_env("GITHUB_STEP_SUMMARY") do
      File.write!(path, Eval.format_markdown(report, source: "adversarial fixture"), [:append])
    end

    for line <- baseline_drift(report.summary, baselines) do
      if System.get_env("GITHUB_ACTIONS"),
        do: IO.puts("::notice title=Search ranking fixture::#{line}")

      IO.puts(:stderr, "search ranking fixture: " <> line)
    end

    failures = Eval.failures(report.summary, gates)

    assert failures == [],
           "the adversarial ranking fixture failed its gates:\n\n" <>
             Enum.map_join(
               failures,
               "\n",
               &"  #{&1.class} recall@#{&1.k} #{format(&1.actual)} < #{&1.min}"
             ) <>
             "\n\n" <> Eval.format_text(report)
  end

  # One line per baseline figure the run no longer matches (to the three
  # decimals the report prints).
  defp baseline_drift(summary, baselines) do
    for {class, recorded} <- baselines,
        {metric, expected} <- recorded,
        actual = metric_value(summary.classes[class], metric),
        not (is_number(actual) and abs(actual - expected) < 0.0005) do
      "#{class} #{metric} moved from #{expected} to #{format(actual)}; " <>
        "update \"baselines\" in #{Path.relative_to_cwd(@golden)}, " <>
        "or promote the class to a gate"
    end
  end

  defp metric_value(nil, _metric), do: nil
  defp metric_value(stats, "mrr"), do: stats.mrr
  defp metric_value(stats, "r@" <> k), do: stats.recall[String.to_integer(k)]

  defp format(nil), do: "nothing (no rows)"
  defp format(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)
end
