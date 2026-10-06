defmodule KilnCMS.Organize.Queue do
  @moduledoc """
  The under-organized queue (#1596): documents the vocabulary has not caught
  up with. Two legs, each row saying which it is on:

    * **No tags** — any state, read as the actor, newest first, at most
      `bound(:untermed_limit)` (50). Pure SQL; no vectors. A row says whether
      the document also has no category (`missing: :none`) or only no tags
      (`:no_tags`) — tags are what the review can propose, so they are what
      this leg is about; a document with tags but no category is not
      under-organized on a site that doesn't use categories.
    * **Far from every tag** — published documents with stored vectors, at
      most `bound(:far_limit)` (100), whose centroid sits further than
      `KilnCMS.Search.suggest_tags_threshold/0` from **every** tag's stored
      name vector. Tagged or not: a document no word in the vocabulary
      describes is a vocabulary gap even if someone attached a tag to it.
      Tags only — categories have no vector — and the first
      `bound(:term_limit)` by name (`vocabulary_truncated?` says when there
      are more).

  Zero inference: stored centroids (`Clusters.centroids/2`) against stored tag
  vectors, in memory. Measured at the bounds (100 documents × 500 tags × 384
  dimensions): ~150 ms on a lean build. Empty when semantic search is off.
  """
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Clusters
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Organize.Vectors

  @typedoc "The queue."
  @type t :: %{
          untagged: [%{doc: Candidates.t(), missing: :none | :no_tags}],
          untagged_truncated?: boolean(),
          far: [%{doc: Candidates.t(), nearest: {Terms.t(), float()} | nil}],
          far_considered: non_neg_integer(),
          far_truncated?: boolean(),
          vocabulary_indexed?: boolean(),
          vocabulary_truncated?: boolean()
        }

  @empty %{
    untagged: [],
    untagged_truncated?: false,
    far: [],
    far_considered: 0,
    far_truncated?: false,
    vocabulary_indexed?: false,
    vocabulary_truncated?: false
  }

  @doc "The queue for the actor. Empty when semantic search is off."
  @spec build(term(), term()) :: t()
  def build(org, actor) do
    if Organize.enabled?(), do: compute(org, actor), else: @empty
  end

  defp compute(org, actor) do
    %{rows: untagged, truncated?: untagged_truncated?} =
      Candidates.bounded(org, actor,
        limit: Organize.bound(:untermed_limit),
        filter: Terms.untagged_filter()
      )

    %{rows: published, truncated?: far_truncated?} =
      Candidates.bounded(org, actor, limit: Organize.bound(:far_limit), state: :published)

    tags = Terms.tags(org, actor)
    vectors = Terms.tag_vectors(org, tags)
    indexed = for tag <- tags, v = Map.get(vectors, tag.id), do: {tag, Vectors.normalize(v)}
    centroids = Clusters.centroids(org, Enum.map(published, & &1.id))

    %{
      untagged: Enum.map(untagged, &%{doc: &1, missing: missing(&1)}),
      untagged_truncated?: untagged_truncated?,
      far: far(published, centroids, indexed),
      far_considered: map_size(centroids),
      far_truncated?: far_truncated?,
      vocabulary_indexed?: indexed != [],
      vocabulary_truncated?: length(tags) >= Organize.bound(:term_limit)
    }
  end

  defp missing(doc) do
    case Terms.missing(doc) do
      :none -> :none
      _no_tags -> :no_tags
    end
  end

  # No indexed tag at all: "far from every tag" would flag the whole library,
  # which says nothing about the documents. The console asks for the tag index
  # instead (`vocabulary_indexed?: false`).
  defp far(_published, _centroids, []), do: []

  defp far(published, centroids, indexed) do
    threshold = KilnCMS.Search.suggest_tags_threshold()

    for doc <- published,
        centroid = Map.get(centroids, doc.id),
        {tag, distance} = nearest(Vectors.normalize(centroid), indexed),
        distance > threshold do
      %{doc: doc, nearest: {tag, distance}}
    end
    |> Enum.sort_by(fn %{nearest: {_tag, d}} -> -d end)
  end

  defp nearest(v, indexed) do
    indexed
    |> Enum.map(fn {tag, t} -> {tag, 1.0 - Vectors.dot(v, t)} end)
    |> Enum.min_by(&elem(&1, 1))
  end
end
