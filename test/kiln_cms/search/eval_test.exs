defmodule KilnCMS.Search.EvalTest do
  @moduledoc """
  The pure half of `mix kiln.search.eval`: golden-set validation, judging,
  recall@k, MRR, junk pass/fail, aggregation, thresholds and rendering. No
  database — the hits are hand-built, so every number here is one the reader
  can check by hand, and a wrong `<` in the metric shows up as a wrong number
  rather than as a slightly different report.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search.Eval

  doctest Eval, import: true

  defp row(query, expected, class, extra \\ []) do
    %{
      query: query,
      expected: expected,
      class: class,
      type: extra[:type],
      locale: extra[:locale]
    }
  end

  defp hit(slug, extra \\ []) do
    %{
      slug: slug,
      type: Keyword.get(extra, :type, "page"),
      section: Keyword.get(extra, :section, "pages"),
      score: Keyword.get(extra, :score, 0.01),
      legs: Keyword.get(extra, :legs, ["keyword"])
    }
  end

  describe "parse/1" do
    test "accepts a bare array, or an object wrapping one" do
      json = ~s([{"query": "a", "expected": ["a"], "class": "typo"}])
      assert {:ok, [row]} = Eval.parse(json)
      assert row == %{query: "a", expected: ["a"], class: "typo", type: nil, locale: nil}

      assert {:ok, [^row]} = Eval.parse(~s({"rows": #{json}}))
      assert {:ok, [^row]} = Eval.parse(~s({"queries": #{json}}))
    end

    test "keeps type and locale, trims the query, dedupes expected" do
      json =
        ~s([{"query": " huang qi ", "expected": ["huang-qi", "huang-qi"], "class": "single_entity", "type": "herb", "locale": "fr"}])

      assert {:ok, [row]} = Eval.parse(json)
      assert row.query == "huang qi"
      assert row.expected == ["huang-qi"]
      assert row.type == "herb"
      assert row.locale == "fr"
    end

    test "every problem names the row and the field" do
      assert {:error, msg} = Eval.parse(~s([{"expected": ["a"], "class": "typo"}]))
      assert msg == ~s(row 0: "query" must be a string)

      assert {:error, msg} = Eval.parse(~s([{"query": "  ", "expected": ["a"], "class": "typo"}]))
      assert msg == ~s(row 0: "query" is blank)

      assert {:error, msg} = Eval.parse(~s([{"query": "a", "expected": ["a"], "class": "herb"}]))
      assert msg =~ ~s(row 0: "class" must be one of single_entity, multi_entity)

      assert {:error, msg} = Eval.parse(~s([{"query": "a", "class": "typo"}]))
      assert msg == ~s(row 0: "expected" must be a list of slugs)

      assert {:error, msg} = Eval.parse(~s([{"query": "a", "expected": [""], "class": "typo"}]))
      assert msg == ~s(row 0: "expected" must be a list of non-empty slugs)

      ok = ~s({"query": "a", "expected": ["a"], "class": "typo"})

      assert {:error, msg} =
               Eval.parse(
                 ~s([#{ok}, {"query": "a", "expected": ["a"], "class": "typo", "type": 3}])
               )

      assert msg == ~s(row 1: "type" must be a non-empty string when present)
    end

    test "junk must expect nothing, and nothing else may" do
      assert {:error, msg} = Eval.parse(~s([{"query": "zz", "expected": ["a"], "class": "junk"}]))
      assert msg == ~s|row 0: a junk row must expect nothing ("expected": [])|

      assert {:error, msg} = Eval.parse(~s([{"query": "a", "expected": [], "class": "typo"}]))
      assert msg == "row 0: a typo row must expect at least one slug"

      assert {:ok, [%{class: "junk", expected: []}]} =
               Eval.parse(~s([{"query": "zz", "expected": [], "class": "junk"}]))
    end

    test "an empty set, a non-array, and malformed JSON are errors" do
      assert {:error, "the golden set has no rows"} = Eval.parse("[]")
      assert {:error, msg} = Eval.parse(~s({"foo": 1}))
      assert msg =~ "expected a JSON array of rows"
      assert {:error, msg} = Eval.parse("[{")
      assert is_binary(msg)
      assert {:error, "row 0: expected an object"} = Eval.parse("[1]")
    end

    test "the shipped example parses and covers every class" do
      json = File.read!(Path.join([:code.priv_dir(:kiln_cms), "search_eval", "example.json"]))
      assert {:ok, rows} = Eval.parse(json)

      assert rows |> Enum.map(& &1.class) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(Eval.classes())
    end
  end

  describe "judge/2" do
    test "assigns each expected slug the rank it landed at, with its legs" do
      judged =
        Eval.judge(row("q", ["b", "z", "a"], "multi_entity"), [
          hit("a", legs: ["keyword", "semantic"]),
          hit("x"),
          hit("b", legs: ["fuzzy"])
        ])

      assert judged.expected == [
               %{slug: "b", rank: 3, legs: ["fuzzy"]},
               %{slug: "z", rank: nil, legs: []},
               %{slug: "a", rank: 1, legs: ["keyword", "semantic"]}
             ]

      assert judged.returned == 3
      assert judged.returned_slugs == ["a", "x", "b"]
      assert judged.class == "multi_entity"
      assert judged.query == "q"
    end

    test "a typed row ranks within that type only — by type name or section plural" do
      hits = [
        hit("a", type: "post", section: "posts"),
        hit("b", type: "herb", section: "herbs"),
        hit("c", type: "herb", section: "herbs")
      ]

      by_type = Eval.judge(row("q", ["c"], "single_entity", type: "herb"), hits)
      assert by_type.expected == [%{slug: "c", rank: 2, legs: ["keyword"]}]
      assert by_type.returned == 2

      by_section = Eval.judge(row("q", ["c"], "single_entity", type: "herbs"), hits)
      assert by_section.expected == [%{slug: "c", rank: 2, legs: ["keyword"]}]

      untyped = Eval.judge(row("q", ["c"], "single_entity"), hits)
      assert untyped.expected == [%{slug: "c", rank: 3, legs: ["keyword"]}]
    end

    test "a slug returned twice occupies one rank, the first" do
      # Two records sharing a slug across types come back as DIFFERENT hits
      # (score, legs, section) — the dedupe is by slug, not by hit.
      judged =
        Eval.judge(row("q", ["a", "b"], "multi_entity"), [
          hit("a", score: 0.02, legs: ["keyword"]),
          hit("a", score: 0.01, legs: ["fuzzy"], section: "posts", type: "post"),
          hit("b")
        ])

      assert judged.expected == [
               %{slug: "a", rank: 1, legs: ["keyword"]},
               %{slug: "b", rank: 2, legs: ["keyword"]}
             ]

      assert judged.returned == 2
      assert judged.returned_slugs == ["a", "b"]
    end
  end

  describe "recall_at/2" do
    test "is the share of expected slugs at or above k" do
      judged =
        Eval.judge(row("q", ["a", "b", "c"], "multi_entity"), for(s <- ~w(a x b y c), do: hit(s)))

      # ranks: a=1, b=3, c=5
      assert Eval.recall_at(judged, 1) == 1 / 3
      assert Eval.recall_at(judged, 2) == 1 / 3
      assert Eval.recall_at(judged, 3) == 2 / 3
      assert Eval.recall_at(judged, 4) == 2 / 3
      assert Eval.recall_at(judged, 5) == 1.0
      assert Eval.recall_at(judged, 10) == 1.0
    end

    test "is 0.0 when nothing expected surfaced" do
      judged = Eval.judge(row("q", ["a"], "single_entity"), [hit("x")])
      assert Eval.recall_at(judged, 10) == 0.0
    end

    test "a junk row is pass/fail at every k" do
      pass = Eval.judge(row("zz", [], "junk"), [])
      fail = Eval.judge(row("zz", [], "junk"), [hit("x")])

      for k <- [1, 3, 10] do
        assert Eval.recall_at(pass, k) == 1.0
        assert Eval.recall_at(fail, k) == 0.0
      end

      assert Eval.junk_passed?(pass)
      refute Eval.junk_passed?(fail)
    end
  end

  describe "reciprocal_rank/1" do
    test "is one over the best rank any expected slug reached" do
      judged = Eval.judge(row("q", ["c", "b"], "multi_entity"), for(s <- ~w(a b c), do: hit(s)))
      assert Eval.reciprocal_rank(judged) == 0.5

      first = Eval.judge(row("q", ["a"], "single_entity"), for(s <- ~w(a b c), do: hit(s)))
      assert Eval.reciprocal_rank(first) == 1.0

      fourth = Eval.judge(row("q", ["d"], "single_entity"), for(s <- ~w(a b c d), do: hit(s)))
      assert Eval.reciprocal_rank(fourth) == 0.25
    end

    test "is 0.0 when nothing expected surfaced, and pass/fail for junk" do
      assert Eval.reciprocal_rank(Eval.judge(row("q", ["a"], "single_entity"), [hit("x")])) == 0.0
      assert Eval.reciprocal_rank(Eval.judge(row("zz", [], "junk"), [])) == 1.0
      assert Eval.reciprocal_rank(Eval.judge(row("zz", [], "junk"), [hit("x")])) == 0.0
    end
  end

  describe "summarize/2" do
    test "macro-averages per class and overall" do
      judged = [
        # single_entity: a at 1 → r@1 1, rr 1
        Eval.judge(row("q1", ["a"], "single_entity"), [hit("a")]),
        # single_entity: a at 2 → r@1 0, r@3 1, rr 0.5
        Eval.judge(row("q2", ["a"], "single_entity"), [hit("x"), hit("a")]),
        # junk fail → 0 everywhere
        Eval.judge(row("zz", [], "junk"), [hit("x")])
      ]

      summary = Eval.summarize(judged, [1, 3])

      assert summary.classes["single_entity"] == %{
               queries: 2,
               recall: %{1 => 0.5, 3 => 1.0},
               mrr: 0.75
             }

      assert summary.classes["junk"] == %{queries: 1, recall: %{1 => 0.0, 3 => 0.0}, mrr: 0.0}
      assert summary.overall == %{queries: 3, recall: %{1 => 1 / 3, 3 => 2 / 3}, mrr: 0.5}
      refute Map.has_key?(summary.classes, "typo")
    end

    test "an empty set is all zeros" do
      assert Eval.summarize([], [1]) == %{
               overall: %{queries: 0, recall: %{1 => 0.0}, mrr: 0.0},
               classes: %{}
             }
    end
  end

  describe "report/3" do
    test "judges every row with the hits the retriever returns for it" do
      rows = [row("one", ["a"], "single_entity"), row("zz", [], "junk")]

      report =
        Eval.report(
          rows,
          fn
            %{query: "one"} -> [hit("a")]
            %{query: "zz"} -> []
          end,
          [1, 5]
        )

      assert report.ks == [1, 5]
      assert Enum.map(report.queries, & &1.query) == ["one", "zz"]
      assert report.summary.overall == %{queries: 2, recall: %{1 => 1.0, 5 => 1.0}, mrr: 1.0}
    end
  end

  describe "failures/2" do
    setup do
      judged = [
        Eval.judge(row("q1", ["a"], "single_entity"), [hit("x"), hit("a")]),
        Eval.judge(row("zz", [], "junk"), [])
      ]

      %{summary: Eval.summarize(judged, [1, 3])}
    end

    test "empty with no thresholds, and when every threshold holds", %{summary: summary} do
      assert Eval.failures(summary, []) == []

      assert Eval.failures(summary, [
               %{class: "single_entity", k: 3, min: 1.0},
               %{class: "junk", k: 1, min: 1.0},
               %{class: "overall", k: 1, min: 0.5}
             ]) == []
    end

    test "names each threshold not met, with the actual figure", %{summary: summary} do
      assert Eval.failures(summary, [%{class: "single_entity", k: 1, min: 0.9}]) ==
               [%{class: "single_entity", k: 1, min: 0.9, actual: 0.0}]

      # Exactly at the threshold passes; a hair under does not.
      assert Eval.failures(summary, [%{class: "overall", k: 1, min: 0.5}]) == []
      assert [_] = Eval.failures(summary, [%{class: "overall", k: 1, min: 0.5001}])
    end

    test "a threshold on an absent class or an unreported k fails rather than passing",
         %{summary: summary} do
      assert [%{class: "typo", actual: nil}] =
               Eval.failures(summary, [%{class: "typo", k: 1, min: 0.1}])

      assert [%{class: "single_entity", k: 7, actual: nil}] =
               Eval.failures(summary, [%{class: "single_entity", k: 7, min: 0.1}])
    end
  end

  describe "parse_threshold/2" do
    test "accepts the classes and overall, bounds MIN, requires a positive K" do
      assert {:ok, %{class: "junk", k: 1, min: 1.0}} = Eval.parse_threshold("junk=1.0@1", 10)
      assert {:ok, %{class: "typo", k: 10, min: +0.0}} = Eval.parse_threshold("typo=0", 10)
      assert {:error, _} = Eval.parse_threshold("typo=1.5", 10)
      assert {:error, _} = Eval.parse_threshold("typo=0.5@0", 10)
      assert {:error, _} = Eval.parse_threshold("typo=0.5@x", 10)
      assert {:error, _} = Eval.parse_threshold("typo", 10)
      assert {:error, _} = Eval.parse_threshold("typo=abc", 10)
    end
  end

  describe "rendering" do
    setup do
      rows = [
        row("huang qi dang shen", ["huang-qi", "dang-shen"], "multi_entity", type: "herb"),
        row("asdf", [], "junk"),
        row("zzz", [], "junk")
      ]

      report =
        Eval.report(
          rows,
          fn
            %{query: "huang qi dang shen"} ->
              [
                hit("da-ding-huang", type: "herb", section: "herbs"),
                hit("huang-qi", type: "herb", section: "herbs", legs: ["keyword", "fuzzy"])
              ]

            %{query: "asdf"} ->
              []

            %{query: "zzz"} ->
              for s <- ~w(a b c d e), do: hit(s)
          end,
          [1, 5]
        )

      %{report: report}
    end

    test "the text report carries the table and a rank line per expected slug", %{report: report} do
      text = Eval.format_text(report, source: "global (in-process)")

      assert text =~ "Search eval — 3 queries, source: global (in-process), k = 1,5"
      assert text =~ ~r/^multi_entity\s+1\s+0\.000\s+0\.500\s+0\.500$/m
      assert text =~ ~r/^junk\s+2\s+0\.500\s+0\.500\s+0\.500$/m
      assert text =~ ~r/^overall\s+3\s+0\.333\s+0\.500\s+0\.500$/m
      assert text =~ ~s|[multi_entity] "huang qi dang shen" (type: herb)|
      assert text =~ ~r/^    huang-qi\s+#2  keyword, fuzzy$/m
      assert text =~ ~r/^    dang-shen\s+missing$/m
      assert text =~ ~s|[junk] "asdf"  PASS  (0 returned)|
      assert text =~ ~s|[junk] "zzz"  FAIL  (5 returned: a, b, c, … +2)|
    end

    test "the markdown summary lists the misses", %{report: report} do
      md = Eval.format_markdown(report, source: "global (in-process)")

      assert md =~ "### Search ranking eval (global (in-process), 3 queries)"
      assert md =~ "| `multi_entity` | 1 | 0.000 | 0.500 | 0.500 |"
      assert md =~ "| **overall** | 3 | 0.333 | 0.500 | 0.500 |"
      assert md =~ "- `huang qi dang shen` → `dang-shen` missing"
      assert md =~ "- `zzz` returned 5 (junk should return nothing)"
      refute md =~ "huang-qi` missing"
    end

    test "the JSON map round-trips through Jason with string keys for k", %{report: report} do
      json = report |> Eval.to_json_map(source: "x") |> Jason.encode!() |> Jason.decode!()

      assert json["source"] == "x"
      assert json["ks"] == [1, 5]
      assert json["summary"]["classes"]["multi_entity"]["recall"] == %{"1" => 0.0, "5" => 0.5}
      assert json["summary"]["overall"]["mrr"] == 0.5

      [multi, junk_pass, _junk_fail] = json["queries"]

      assert multi["expected"] == [
               %{"slug" => "huang-qi", "rank" => 2, "legs" => ["keyword", "fuzzy"]},
               %{"slug" => "dang-shen", "rank" => nil, "legs" => []}
             ]

      assert multi["recall"] == %{"1" => 0.0, "5" => 0.5}
      assert multi["reciprocal_rank"] == 0.5
      assert multi["type"] == "herb"
      assert junk_pass["returned"] == 0
      assert junk_pass["reciprocal_rank"] == 1.0
    end
  end
end
