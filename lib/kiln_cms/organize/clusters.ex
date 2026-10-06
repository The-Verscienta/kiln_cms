defmodule KilnCMS.Organize.Clusters do
  @moduledoc """
  Semantic clusters as a browse axis over the library (#1596): the actor's
  published documents grouped by what they are about, whatever they happen to
  be tagged.

  ## What is clustered

  Published documents only. They are the ones with stored block vectors —
  vectors are written on publish (D16), and a draft's would cost one model
  inference per block (`KilnCMS.Search.Related`'s centroid fallback). This
  surface never infers: one `KilnCMS.Organize.Candidates` read (authorized as
  the actor), one SQL-averaged centroid per document
  (`KilnCMS.Search.DocumentCentroids`), then `KilnCMS.Organize.Vectors.kmeans/2`
  in the BEAM. A published document with no stored vectors yet (semantic search
  switched on without a re-fire) is counted in `:unindexed` rather than
  silently dropped.

  At most `KilnCMS.Organize.bound(:cluster_limit)` documents (default 300), the
  most recently updated. `k = clamp(round(√(n/2)), 2, 12)`.

  ## Labels

  Each cluster is labelled by the nearest **stored** tag-name vector to its
  center: `{:tag, term, distance}` when one sits within
  `KilnCMS.Search.suggest_tags_threshold/0` — the measured ceiling for "a tag a
  human would tick" — or `:uncovered`, a group of documents no tag in the
  vocabulary describes: a missing term, the organization signal this surface
  exists to surface. Tags with no stored vector yet cannot label anything;
  `KilnCMS.Organize.Terms.index_tag_vectors/2` fills them.

  ## Cost

  Measured on a lean build (OTP 29, Apple-silicon laptop, 2026-10-06):

  | step, at the default bound | time |
  |---|---|
  | centroid query, 300 documents × 20 blocks (6 000 rows) | ~15 ms |
  | k-means, 300 × 384-d centroids, k = 12 | ~90 ms |

  Memory is the 300 centroids (~300 × 384 floats), not the 6 000 block
  vectors. Computed on tab open, in `start_async`, never in `mount/3`.
  """
  alias KilnCMS.Organize
  alias KilnCMS.Organize.Candidates
  alias KilnCMS.Organize.Terms
  alias KilnCMS.Organize.Vectors

  @typedoc "One cluster: its members nearest-center first, and its label."
  @type cluster :: %{
          members: [Candidates.t()],
          label: {:tag, Terms.t(), float()} | :uncovered
        }

  @typedoc "The browse result."
  @type result :: %{clusters: [cluster()], unindexed: non_neg_integer()}

  @doc "Clusters of the actor's published documents. Empty when semantic search is off."
  @spec browse(term(), term()) :: result()
  def browse(org, actor) do
    if Organize.enabled?(), do: compute(org, actor), else: %{clusters: [], unindexed: 0}
  end

  defp compute(org, actor) do
    candidates =
      Candidates.list(org, actor, limit: Organize.bound(:cluster_limit), state: :published)

    by_id = Map.new(candidates, &{&1.id, &1})
    centroids = centroids(org, Map.keys(by_id))
    points = for {id, v} <- centroids, do: {id, Vectors.normalize(v)}
    labeller = labeller(org, actor)

    clusters =
      points
      |> Vectors.kmeans(k(length(points)))
      |> Enum.map(fn {center, ids} ->
        %{members: Enum.map(ids, &Map.fetch!(by_id, &1)), label: labeller.(center)}
      end)

    %{clusters: clusters, unindexed: map_size(by_id) - length(points)}
  end

  @doc false
  # `k` for `n` points — exposed for the test that pins it.
  @spec k(non_neg_integer()) :: non_neg_integer()
  def k(n) when n < 2, do: n
  def k(n), do: (n / 2) |> :math.sqrt() |> round() |> max(2) |> min(12) |> min(n)

  @doc """
  `%{document_id => centroid}` for the given ids under `org` — read as the
  search system actor, for ids the caller already authorized.
  """
  @spec centroids(term(), [Ash.UUID.t()]) :: %{Ash.UUID.t() => [float()]}
  def centroids(_org, []), do: %{}

  def centroids(org, ids) do
    ids
    |> KilnCMS.SearchIndex.document_centroids!(
      # The embedding index admits the search system actor (#1402). The ids
      # are the caller's own authorized candidates — see `Candidates`.
      actor: KilnCMS.SystemActor.new(:search),
      tenant: KilnCMS.Accounts.org_id(org)
    )
    |> Map.new(&{&1.document_id, &1.centroid})
  end

  @doc """
  A function labelling a unit vector with the nearest stored tag within
  `suggest_tags_threshold/0`, or `:uncovered`. Loads the actor's tags and
  their vectors once.
  """
  @spec labeller(term(), term()) :: ([float()] -> {:tag, Terms.t(), float()} | :uncovered)
  def labeller(org, actor) do
    tags = Terms.tags(org, actor)
    vectors = Terms.tag_vectors(org, tags)
    threshold = KilnCMS.Search.suggest_tags_threshold()

    indexed =
      for tag <- tags, v = Map.get(vectors, tag.id), do: {tag, Vectors.normalize(v)}

    fn center -> nearest_tag(center, indexed, threshold) end
  end

  defp nearest_tag(_center, [], _threshold), do: :uncovered

  defp nearest_tag(center, indexed, threshold) do
    {tag, distance} =
      indexed
      |> Enum.map(fn {tag, v} -> {tag, 1.0 - Vectors.dot(center, v)} end)
      |> Enum.min_by(&elem(&1, 1))

    if distance <= threshold, do: {:tag, tag, distance}, else: :uncovered
  end
end
