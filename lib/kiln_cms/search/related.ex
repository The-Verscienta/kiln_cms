defmodule KilnCMS.Search.Related do
  @moduledoc """
  Embedding-driven content intelligence (#339, phase 2), built entirely on the
  block embeddings that already index every document (D16) — no new model, no
  external calls:

    * `related_documents/2` — "readers of this also want…", the public
      related-content surface (published documents only).
    * `near_duplicates/2` — documents whose content is suspiciously close to
      this one (any state — editors want to catch draft duplicates too).
    * `suggest_tags/2` — existing tags ranked by semantic similarity to the
      document, minus the ones already applied.
    * `content_gaps/2` — recorded search queries that found little or nothing
      (from the search-analytics log): what readers looked for and didn't get.

  Everything is org-scoped and a no-op (empty results) when semantic search is
  disabled, mirroring the rest of the search stack.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search

  @typedoc "A scored neighbouring document."
  @type neighbour :: %{
          type: String.t(),
          id: Ash.UUID.t(),
          slug: String.t(),
          title: String.t() | nil,
          distance: float()
        }

  @doc """
  Published documents most similar to `record` (nearest block embeddings,
  aggregated per document by minimum cosine distance). Options: `:limit`
  (default 5).
  """
  @spec related_documents(struct(), keyword()) :: [neighbour()]
  def related_documents(record, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    record
    |> neighbours(limit * 4)
    |> resolve(record.org_id, published_only?: true)
    |> Enum.take(limit)
  end

  @doc """
  Documents whose closest block sits within `:threshold` cosine distance of
  this document (default 0.1) — near-duplicates, any workflow state.
  """
  @spec near_duplicates(struct(), keyword()) :: [neighbour()]
  def near_duplicates(record, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.1)

    record
    |> neighbours(Keyword.get(opts, :limit, 20))
    |> Enum.filter(&(&1.distance <= threshold))
    |> resolve(record.org_id, published_only?: false)
  end

  @doc """
  Existing tags ranked by similarity to the document's content, excluding the
  ones already applied. Returns `[%{tag, distance}]`, best first. Options:
  `:limit` (default 5).
  """
  @spec suggest_tags(struct(), keyword()) :: [%{tag: struct(), distance: float()}]
  def suggest_tags(record, opts \\ []) do
    with true <- Search.semantic?(),
         centroid when is_list(centroid) <- centroid(record) do
      applied =
        record
        |> Map.get(:tags)
        |> List.wrap()
        |> Enum.reject(&match?(%Ash.NotLoaded{}, &1))
        |> MapSet.new(& &1.id)

      KilnCMS.CMS.list_tags!(authorize?: false, tenant: record.org_id)
      |> Enum.reject(&MapSet.member?(applied, &1.id))
      |> Enum.flat_map(fn tag ->
        case tag_vector(tag.name) do
          vector when is_list(vector) ->
            [%{tag: tag, distance: cosine_distance(centroid, vector)}]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(& &1.distance)
      |> Enum.take(Keyword.get(opts, :limit, 5))
    else
      _ -> []
    end
  end

  @doc """
  Recorded search queries that found nothing — what readers looked for and
  the site didn't have (the Analytics `:zero_result` read). Options:
  `:limit` (default 20, most-searched first).
  """
  @spec content_gaps(Ash.UUID.t(), keyword()) :: [map()]
  def content_gaps(org_id, opts \\ []) do
    KilnCMS.Analytics.zero_result_searches!(
      authorize?: false,
      tenant: org_id,
      query: [limit: Keyword.get(opts, :limit, 20)]
    )
    |> Enum.map(&%{query: &1.query, searches: &1.count, results: &1.result_count})
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Nearest foreign block embeddings to this document's centroid, aggregated
  # per document by minimum distance.
  defp neighbours(record, fetch_limit) do
    with true <- Search.semantic?(),
         centroid when is_list(centroid) <- centroid(record) do
      KilnCMS.SearchIndex.nearest_block_embeddings!(
        %{vector: centroid, exclude_document_id: record.id, limit: fetch_limit * 3},
        authorize?: false,
        tenant: record.org_id,
        load: [semantic_distance: %{query_vector: centroid}]
      )
      |> Enum.group_by(&{&1.document_type, &1.document_id})
      |> Enum.map(fn {{type, id}, embeddings} ->
        {type, id, embeddings |> Enum.map(& &1.semantic_distance) |> Enum.min()}
      end)
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.take(fetch_limit)
      |> Enum.map(fn {type, id, distance} -> %{type: type, id: id, distance: distance} end)
    else
      _ -> []
    end
  end

  # The document's embedding centroid: the element-wise mean of its block
  # vectors (hierarchical embeddings already fold in ancestor context).
  defp centroid(record) do
    storage = KilnCMS.Firing.Engine.document_type(record)

    vectors =
      KilnCMS.SearchIndex.block_embeddings_for!(storage, record.id,
        authorize?: false,
        tenant: record.org_id
      )
      |> Enum.map(&to_list(&1.embedding))
      |> Enum.reject(&is_nil/1)

    case vectors do
      [] -> nil
      _ -> mean(vectors)
    end
  end

  defp resolve(neighbours, org_id, published_only?: published_only?) do
    Enum.flat_map(neighbours, fn %{type: storage, id: id, distance: distance} ->
      case ContentTypes.get_record(to_string(storage), id, authorize?: false, tenant: org_id) do
        {:ok, doc} -> neighbour_entry(doc, distance, published_only?)
        _ -> []
      end
    end)
  end

  defp neighbour_entry(doc, _distance, true) when doc.state != :published, do: []

  defp neighbour_entry(doc, distance, _published_only?) do
    [
      %{
        type: KilnCMS.Firing.Engine.public_type(doc),
        id: doc.id,
        slug: doc.slug,
        title: doc.title,
        distance: distance
      }
    ]
  end

  # Tag-name vectors are pure functions of the (stable) name — memoized so a
  # 500-tag org doesn't re-run 500 model inferences per triggering event.
  defp tag_vector(name) do
    KilnCMS.Cache.fetch({:tag_vector, Search.model(), name}, :timer.hours(6), fn ->
      case Search.embed_document(name) do
        {:ok, vector} -> vector
        _ -> nil
      end
    end)
  end

  defp mean(vectors) do
    count = length(vectors)

    vectors
    |> Enum.zip_with(& &1)
    |> Enum.map(&(Enum.sum(&1) / count))
  end

  defp cosine_distance(a, b) do
    dot = a |> Enum.zip_with(b, &*/2) |> Enum.sum()

    norm =
      :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1)))) *
        :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))

    if norm == 0.0, do: 1.0, else: 1.0 - dot / norm
  end

  # Stored vectors round-trip as `Pgvector` structs or plain lists.
  defp to_list(nil), do: nil
  defp to_list(%Pgvector{} = v), do: Pgvector.to_list(v)
  defp to_list(list) when is_list(list), do: list
end
