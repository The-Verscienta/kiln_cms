defmodule KilnCMS.Search.RerankOrderTest do
  @moduledoc """
  The ordering rules of reranking (#1938, #1937), without a model or a
  database: `:replace`, the `{:rrf, k}` blend of fused rank and rerank rank,
  the named-entity pin, and the operator's spelling of a mode.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search
  alias KilnCMS.Search.RerankOrder

  # Hits in fused order: `{name, fused_score, legs}`.
  defp hits(names, legs \\ %{}) do
    names
    |> Enum.with_index()
    |> Enum.map(fn {name, i} -> {name, 1.0 / (60 + i + 1), Map.get(legs, name, [:keyword])} end)
  end

  defp names(hits), do: Enum.map(hits, &elem(&1, 0))

  describe "order/3 with :replace" do
    test "is the reranker's order, carrying the reranker's score" do
      assert [{:c, 0.9, _}, {:a, 0.5, _}, {:b, 0.1, _}] =
               RerankOrder.order(hits([:a, :b, :c]), [0.5, 0.1, 0.9], :replace)
    end

    test "equal reranker scores keep the fused order" do
      assert names(RerankOrder.order(hits([:a, :b, :c]), [0.2, 0.7, 0.7], :replace)) ==
               [:b, :c, :a]
    end

    test "keeps each hit's legs" do
      [{:b, _, legs} | _] =
        RerankOrder.order(hits([:a, :b], %{b: [:title, :keyword]}), [0.0, 1.0], :replace)

      assert legs == [:title, :keyword]
    end
  end

  describe "order/3 with {:rrf, k}" do
    test "scores each hit 1/(k + fused rank) + 1/(k + rerank rank) and orders by it" do
      # Fused: a, b, c, d. Reranker: d, c, b, a (a reversal) — except it
      # likes a a little more than b.
      result = RerankOrder.order(hits([:a, :b, :c, :d]), [0.3, 0.2, 0.8, 0.9], {:rrf, 60})

      # Rerank ranks: d 1, c 2, a 3, b 4.
      expected = %{
        a: 1 / 61 + 1 / 63,
        b: 1 / 62 + 1 / 64,
        c: 1 / 63 + 1 / 62,
        d: 1 / 64 + 1 / 61
      }

      for {name, score, _legs} <- result, do: assert_in_delta(score, expected[name], 1.0e-12)

      # 0.032266, 0.032018, 0.032002, 0.031754: the fused leader holds on its
      # third rerank place, d (the reranker's first) comes second, and b —
      # second fused, last reranked — falls to the bottom.
      assert names(result) == [:a, :d, :c, :b]
    end

    test "a hit both orders put first stays first; one only the reranker likes rises part-way" do
      # Fused a..f; the reranker puts f first and otherwise agrees.
      result =
        RerankOrder.order(hits([:a, :b, :c, :d, :e, :f]), [6, 5, 4, 3, 2, 10], {:rrf, 60})

      # Rerank ranks f 1, a 2, b 3, ... a: 1/61 + 1/62 holds first; b:
      # 1/62 + 1/63 holds second; f: 1/66 + 1/61 rises above c, d and e.
      assert names(result) == [:a, :b, :f, :c, :d, :e]
    end

    test "an exact tie in the blend falls to fused order, deterministically" do
      # Two hits, reranker reverses them: a = 1/61 + 1/62 = b = 1/62 + 1/61.
      assert names(RerankOrder.order(hits([:a, :b]), [0.1, 0.9], {:rrf, 60})) == [:a, :b]

      # Same blend, inputs presented in the other fused order: still fused order.
      assert names(RerankOrder.order(hits([:b, :a]), [0.1, 0.9], {:rrf, 60})) == [:b, :a]

      # And the same answer every time.
      runs = for _ <- 1..20, do: RerankOrder.order(hits([:a, :b, :c]), [0, 0, 0], {:rrf, 60})
      assert runs |> Enum.uniq() |> length() == 1
      assert names(hd(runs)) == [:a, :b, :c]
    end

    test "equal reranker scores take consecutive rerank ranks in fused order" do
      # All three scored the same: rerank ranks 1, 2, 3 — the fused order.
      [{:a, sa, _}, {:b, sb, _}, {:c, sc, _}] =
        RerankOrder.order(hits([:a, :b, :c]), [0.5, 0.5, 0.5], {:rrf, 10})

      assert_in_delta sa, 2 / 11, 1.0e-12
      assert_in_delta sb, 2 / 12, 1.0e-12
      assert_in_delta sc, 2 / 13, 1.0e-12
    end

    test "k changes the blend's weight on rank differences" do
      hits = hits([:a, :b, :c, :d, :e, :f, :g, :h])
      scores = [0, 0, 0, 0, 0, 0, 0, 1]
      # The reranker's #1 is h, fused 8th; everything else keeps its order.
      # Small k: a first place is worth far more than an eighth, and h climbs
      # to second (1/9 + 1/2 against a's 1/2 + 1/3). k = 60 flattens the
      # curve, and h only reaches fourth (1/68 + 1/61 against d's 1/64 + 1/65).
      assert hits |> RerankOrder.order(scores, {:rrf, 1}) |> names() |> Enum.take(3) ==
               [:a, :h, :b]

      assert hits |> RerankOrder.order(scores, {:rrf, 60}) |> names() |> Enum.take(5) ==
               [:a, :b, :c, :h, :d]
    end

    test "empty in, empty out" do
      assert RerankOrder.order([], [], {:rrf, 60}) == []
      assert RerankOrder.order([], [], :replace) == []
    end
  end

  describe "pin/3" do
    test "a hit the query names by title keeps its fused position" do
      fused = hits([:a, :named, :c, :d], %{named: [:title, :keyword]})
      # The reranker sinks the named record to last.
      reordered = RerankOrder.order(fused, [0.9, 0.0, 0.8, 0.7], :replace)
      assert names(reordered) == [:a, :c, :d, :named]

      assert names(RerankOrder.pin(fused, reordered)) == [:a, :named, :c, :d]
    end

    test "an :alias hit is pinned the same way; other legs are not" do
      fused =
        hits([:a, :aliased, :fuzzy], %{aliased: [:alias], fuzzy: [:fuzzy, :keyword_any]})

      # The reranker sinks the aliased record below a.
      reordered = RerankOrder.order(fused, [0.5, 0.0, 0.9], :replace)
      assert names(reordered) == [:fuzzy, :a, :aliased]
      assert names(RerankOrder.pin(fused, reordered)) == [:fuzzy, :aliased, :a]
    end

    test "unpinned hits fill the gaps in the reordered list's order" do
      legs = %{p1: [:title], p2: [:alias, :semantic]}
      fused = hits([:p1, :u1, :u2, :p2, :u3], legs)
      # Reranker: u3, u2, p2, u1, p1.
      reordered = RerankOrder.order(fused, [0.0, 0.2, 0.5, 0.4, 0.9], {:rrf, 60})

      # Pins at fused positions 0 and 3; unpinned u-hits fill 1, 2, 4 in the
      # blended order of the unpinned hits alone.
      unpinned_blended =
        reordered |> names() |> Enum.reject(&(&1 in [:p1, :p2]))

      assert [:p1, x, y, :p2, z] = names(RerankOrder.pin(fused, reordered))
      assert [x, y, z] == unpinned_blended
    end

    test "every hit keeps the score the reordering gave it" do
      fused = hits([:a, :named], %{named: [:title]})
      reordered = RerankOrder.order(fused, [0.9, 0.1], :replace)
      assert [{:a, 0.9, _}, {:named, 0.1, _}] = RerankOrder.pin(fused, reordered)

      # Pinned at the top while the reranker scored it lowest: the scores need
      # not descend under the pin.
      fused = hits([:named, :a], %{named: [:title]})
      reordered = RerankOrder.order(fused, [0.1, 0.9], :replace)
      assert [{:named, 0.1, _}, {:a, 0.9, _}] = RerankOrder.pin(fused, reordered)
    end

    test "with nothing pinned it is the reordered list; with everything pinned, the fused one" do
      fused = hits([:a, :b, :c])
      reordered = RerankOrder.order(fused, [0.1, 0.5, 0.9], :replace)
      assert RerankOrder.pin(fused, reordered) == reordered

      all = hits([:a, :b, :c], %{a: [:title], b: [:title], c: [:alias]})
      reordered = RerankOrder.order(all, [0.1, 0.5, 0.9], :replace)
      assert names(RerankOrder.pin(all, reordered)) == [:a, :b, :c]
    end

    test "matches hits between the two lists by key" do
      fused = [{%{id: 1}, 0.03, [:title]}, {%{id: 2}, 0.02, [:keyword]}]
      reordered = [{%{id: 2, x: :new}, 0.9, [:keyword]}, {%{id: 1, x: :new}, 0.1, [:title]}]

      assert [{%{id: 1}, 0.1, _}, {%{id: 2}, 0.9, _}] =
               RerankOrder.pin(fused, reordered, & &1.id)
    end

    test "empty in, empty out" do
      assert RerankOrder.pin([], []) == []
    end
  end

  describe "Search.parse_rerank_mode/1" do
    test "reads replace, rrf and rrf:<k>, trimmed and case-insensitive" do
      assert Search.parse_rerank_mode("replace") == {:ok, :replace}
      assert Search.parse_rerank_mode(" Replace ") == {:ok, :replace}
      assert Search.parse_rerank_mode("rrf") == {:ok, {:rrf, 60}}
      assert Search.parse_rerank_mode("RRF:30") == {:ok, {:rrf, 30}}
      assert Search.parse_rerank_mode("rrf:10000") == {:ok, {:rrf, 10_000}}
    end

    test "refuses anything else rather than guessing" do
      for raw <- ["", "blend", "rrf:", "rrf:0", "rrf:-5", "rrf:6x", "rrf:10001", "rrf 60"] do
        assert Search.parse_rerank_mode(raw) == :error, raw
      end
    end
  end
end
