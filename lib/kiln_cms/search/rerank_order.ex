defmodule KilnCMS.Search.RerankOrder do
  @moduledoc """
  The pure half of reranking: given hits in their **fused** order and the
  reranker's score for each, the order they leave in and the score each one
  carries. No model and no database, so every rule here is unit-tested
  directly (`KilnCMS.Search.RerankOrderTest`).

  A hit is `{item, score, legs}` — the shape `KilnCMS.Search.hybrid/3` fuses
  into, where `item` is the record, `score` the number it is ordered by and
  `legs` the fusion legs that returned it (`KilnCMS.Search.hit_legs/1`).

  ## Modes (#1938)

    * `:replace` — the reranker's order outright, and its score (a 0–1
      sigmoid relevance, see `KilnCMS.Search.RerankerServing.scores_function/1`).
      What reranking always did.
    * `{:rrf, k}` — Reciprocal Rank Fusion of the two orders: a hit's score is
      `1 / (k + fused_rank) + 1 / (k + rerank_rank)`, ranks 1-based. Replacing
      the fused order outright regressed the query classes fusion already gets
      right: on the golden set behind #1938, question-form MRR fell from 0.672
      to 0.388, because the cross-encoder prefers a record that *answers* the
      question over the record the question *names*. A blend lets the fused
      order hold what it is sure of.

  ## The blended score

  A blended hit carries its blend — the number its order came from, which is
  `KilnCMS.Search.hit_score/1`'s contract — between `2 / (k + n)` and
  `2 / (k + 1)` for a list of `n` (0.0328 at k = 60). It is built from *ranks
  within the list that was reranked*, so it compares across hits of one list
  and nothing else. That is exact for `/api/ask`'s union rerank, where the list
  is every content type's candidates at once (`KilnCMS.Ask`). Per section it
  is weaker: two sections' first hits carry nearly the same blend however
  different their relevance, so a caller sorting sections together by score
  interleaves them rank by rank. The reranker's own 0–1 score would compare
  across sections, but then the number would no longer be the one the order
  came from, and a client thresholding or re-sorting on it would undo the
  blend. Documented in docs/rag.md, "Reranking ask sources".

  ## Ties

  Every sort here is stable over the fused order, so a tie — two hits the
  reranker scores the same, or two hits whose blends are equal — keeps the
  fused order. Rerank ranks are distinct for the same reason: equal reranker
  scores take consecutive ranks in fused order, never a shared one. The output
  is deterministic for a given input.
  """

  @typedoc "A fused hit: the item, the score it is ordered by, and its legs."
  @type hit :: {term(), number(), [atom()]}

  @typedoc "How the reranker's order combines with the fused one."
  @type mode :: :replace | {:rrf, pos_integer()}

  @doc """
  Order `hits` (fused order) by `scores` (one per hit, same order) under
  `mode`. Each returned hit carries the score its new order came from.
  """
  @spec order([hit()], [number()], mode()) :: [hit()]
  def order(hits, scores, :replace) when length(hits) == length(scores) do
    hits
    |> Enum.zip(scores)
    |> Enum.map(fn {{item, _fused, legs}, score} -> {item, score, legs} end)
    # Stable: equal reranker scores keep the fused order.
    |> Enum.sort_by(fn {_item, score, _legs} -> score end, :desc)
  end

  def order(hits, scores, {:rrf, k})
      when length(hits) == length(scores) and is_integer(k) and k > 0 do
    rerank_ranks = rerank_ranks(scores)

    hits
    |> Enum.with_index(1)
    |> Enum.zip(rerank_ranks)
    |> Enum.map(fn {{{item, _fused, legs}, fused_rank}, rerank_rank} ->
      {{item, 1 / (k + fused_rank) + 1 / (k + rerank_rank), legs}, fused_rank}
    end)
    # Blend first; an exact tie falls to the fused rank. Spelled out rather
    # than left to sort stability, because "fused order breaks a tie" is the
    # rule (#1937), not an accident of the input's order.
    |> Enum.sort_by(fn {{_item, blend, _legs}, fused_rank} -> {-blend, fused_rank} end)
    |> Enum.map(&elem(&1, 0))
  end

  # The 1-based rank of each score among `scores`, in input order: the highest
  # score is rank 1, and equal scores take consecutive ranks in input (fused)
  # order rather than sharing one.
  @spec rerank_ranks([number()]) :: [pos_integer()]
  defp rerank_ranks(scores) do
    ranks =
      scores
      |> Enum.with_index()
      |> Enum.sort_by(fn {score, index} -> {-score, index} end)
      |> Enum.with_index(1)
      |> Map.new(fn {{_score, index}, rank} -> {index, rank} end)

    Enum.map(0..(length(scores) - 1)//1, &Map.fetch!(ranks, &1))
  end

  @doc """
  The named-entity pin, as #1937 preregistered it: a hit the query names
  (`pinned?/1` — its legs include `:title` or `:alias`) keeps its **fused**
  position; every other hit fills the remaining positions in `reordered`'s
  order.

  `fused` and `reordered` are the same hits in two orders: the fused one, and
  `order/3`'s. Pinned hits are placed first, each at its index in `fused`, so
  two pinned hits can never collide — a fused-score tie was already broken by
  fused order when `fused` was built. The unpinned hits then fill the gaps,
  first gap first, in the order `reordered` has them. Every hit keeps the
  score `reordered` gave it, so under the pin the scores need not descend: a
  pinned hit holds its slot whatever its blend says. The returned order is
  the answer; the scores are each hit's own.

  Hits are matched between the two lists by `key` (default: the item itself).
  """
  @spec pin([hit()], [hit()], (term() -> term())) :: [hit()]
  def pin(fused, reordered, key \\ & &1) do
    pinned_at =
      fused
      |> Enum.with_index()
      |> Enum.filter(fn {hit, _index} -> pinned?(hit) end)
      |> Map.new(fn {{item, _score, _legs}, index} -> {key.(item), index} end)

    by_key = Map.new(reordered, fn {item, _score, _legs} = hit -> {key.(item), hit} end)

    slots =
      Map.new(pinned_at, fn {item_key, index} -> {index, Map.fetch!(by_key, item_key)} end)

    unpinned =
      Enum.reject(reordered, fn {item, _s, _l} -> Map.has_key?(pinned_at, key.(item)) end)

    {placed, []} =
      Enum.map_reduce(0..(length(fused) - 1)//1, unpinned, fn index, rest ->
        case Map.fetch(slots, index) do
          {:ok, hit} -> {hit, rest}
          :error -> {hd(rest), tl(rest)}
        end
      end)

    placed
  end

  @doc """
  Whether the pin holds `hit` at its fused position: the query names it, by
  its title (`:title`) or by a field an admin flagged as one of its names
  (`:alias`). Those are the legs that say "this record is what the question
  is about", which is the judgement a cross-encoder gets wrong — it prefers a
  record that *answers* the question to the one the question names (#1937:
  "what does ST36 treat" fell from @1 to @3 behind point combinations).
  """
  @spec pinned?(hit()) :: boolean()
  def pinned?({_item, _score, legs}), do: :title in legs or :alias in legs
end
