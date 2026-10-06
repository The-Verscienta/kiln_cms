defmodule KilnCMS.Organize.Gaps do
  @moduledoc """
  `KilnCMS.Search.Related.content_gaps/2` read as an organization signal
  (#1596), not an analytics readout: a query readers searched for and found
  nothing is often a **missing term** or a **missing hub page**.

  Each zero-result query (at most `bound(:gap_limit)`, 20, most-searched
  first) is classified by its nearest stored tag-name vector:

    * `{:hub_missing, term, distance}` — a tag within
      `KilnCMS.Search.suggest_tags_threshold/0` already names it, so the
      vocabulary has the word and the library lacks the page: write a hub for
      that tag, or tag the content that should have answered.
    * `:term_missing` — no tag is close: a candidate for a new term (and,
      usually, the content to go with it).
    * `:unclassified` — the classification could not run (no tag vectors yet,
      or no budget for the query embeddings); the gap itself still shows.

  ## Which threshold

  `suggest_tags_threshold/0` (0.35), calibrated for a tag name against a
  *document* centroid — not separately calibrated for a query against a tag
  name, which is short text against short text. By
  `KilnCMS.TermDuplicateCorpus`, related-but-distinct labels sit at
  0.09–0.40, so most queries *related* to an existing tag read as
  `:hub_missing`. That is the intended reading: a nearby term exists, so the
  first fix is a hub page or tagging for it, not a new term. The vocabulary is
  `Terms.tags/2`'s first 500 by name (`vocabulary_truncated?`).

  ## Cost

  The one inference here is the query's own embedding: one per query not
  already in `KilnCMS.Search.VectorCache`, so at most 20 per load and nothing
  on a reload. Charged to `KilnCMS.LLM.Budget` as **one** interactive charge
  for the uncached count (the editor opened the tab), and only when it fits
  the room left in the editor's window (`KilnCMS.Search.embedding_remaining/3`)
  — otherwise the gaps come back `:unclassified` and nothing is charged, so a
  refused charge can never spend the window on failing. Query strings come
  from anonymous readers: they are data, rendered escaped, and never
  interpolated into a URL by hand.
  """
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Organize.Vectors
  alias KilnCMS.Search
  alias KilnCMS.Search.Related
  alias KilnCMS.Search.VectorCache

  @typedoc "A classified gap."
  @type gap :: %{
          query: String.t(),
          searches: non_neg_integer(),
          signal: {:hub_missing, Terms.t(), float()} | :term_missing | :unclassified
        }

  @typedoc "The signals, and why classification was skipped, if it was."
  @type t :: %{
          gaps: [gap()],
          skipped: nil | :no_vectors | {:rate_limited, non_neg_integer()},
          vocabulary_truncated?: boolean()
        }

  @doc "Gap signals for the actor. Empty when semantic search is off."
  @spec signals(term(), term()) :: t()
  def signals(org, actor) do
    if Organize.enabled?(),
      do: compute(org, actor),
      else: %{gaps: [], skipped: nil, vocabulary_truncated?: false}
  end

  defp compute(org, actor) do
    gaps =
      org
      |> Related.content_gaps(actor: actor, limit: Organize.bound(:gap_limit))
      |> Enum.map(&%{query: &1.query, searches: &1.searches, signal: :unclassified})

    tags = Terms.tags(org, actor)
    vectors = Terms.tag_vectors(org, tags)
    indexed = for tag <- tags, v = Map.get(vectors, tag.id), do: {tag, Vectors.normalize(v)}

    result =
      cond do
        gaps == [] -> %{gaps: [], skipped: nil}
        indexed == [] -> %{gaps: gaps, skipped: :no_vectors}
        true -> classify(gaps, indexed, org, actor)
      end

    Map.put(result, :vocabulary_truncated?, length(tags) >= Organize.bound(:term_limit))
  end

  defp classify(gaps, indexed, org, actor) do
    org_id = KilnCMS.Accounts.org_id(org)
    user_id = actor && actor.id

    uncached =
      gaps |> Enum.map(& &1.query) |> Enum.uniq() |> Enum.count(&(not VectorCache.cached?(&1)))

    if fits?(uncached, org_id, user_id) do
      org_id |> charge(user_id, uncached, fn -> embed_all(gaps) end) |> label(gaps, indexed)
    else
      {_count, window_ms} = Search.embedding_per_user_limit()
      %{gaps: gaps, skipped: {:rate_limited, window_ms}}
    end
  end

  defp label({:error, reason}, gaps, _indexed), do: %{gaps: gaps, skipped: reason}

  defp label(query_vectors, gaps, indexed) do
    threshold = Search.suggest_tags_threshold()

    %{
      gaps:
        Enum.map(
          gaps,
          &%{&1 | signal: signal(Map.get(query_vectors, &1.query), indexed, threshold)}
        ),
      skipped: nil
    }
  end

  defp fits?(0, _org_id, _user_id), do: true

  defp fits?(units, org_id, user_id) do
    case Search.embedding_remaining(org_id, user_id, false) do
      :infinity -> true
      room -> units <= room
    end
  end

  defp charge(_org_id, _user_id, 0, fun), do: fun.()

  defp charge(org_id, user_id, units, fun) do
    KilnCMS.LLM.Budget.charge(
      "search_embedding",
      org_id,
      user_id,
      Search.embedding_budget_limits(false, units),
      fun
    )
  end

  defp embed_all(gaps) do
    for %{query: q} <- gaps, into: %{}, do: {q, VectorCache.embed_document(q)}
  end

  defp signal(vector, indexed, threshold) when is_list(vector) do
    v = Vectors.normalize(vector)

    {tag, distance} =
      indexed
      |> Enum.map(fn {tag, t} -> {tag, 1.0 - Vectors.dot(v, t)} end)
      |> Enum.min_by(&elem(&1, 1))

    if distance <= threshold, do: {:hub_missing, tag, distance}, else: :term_missing
  end

  # The embedder answered nothing for this query.
  defp signal(_vector, _indexed, _threshold), do: :unclassified
end
