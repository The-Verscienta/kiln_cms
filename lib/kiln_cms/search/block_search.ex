defmodule KilnCMS.Search.BlockSearch do
  @moduledoc """
  Block-granular semantic search (Kiln v2 — decision D16).

  `search/2` returns the nearest blocks to a query by cosine distance, optionally
  faceted by `:block_type` — the "find the relevant section" query. Keyword/RRF
  fusion over a block-level tsvector is a documented follow-up; this is the
  semantic + faceting core.

  ## The recall contract (#998)

  This is an **approximate** nearest-neighbour search, and every query it runs
  is a *filtered* one — by tenant always, and by `:block_type` or an excluded
  document when the caller asks. pgvector applies those filters to rows the
  HNSW index has already chosen, so the two interact: with pgvector's default
  `hnsw.iterative_scan = off` the scan yields one batch of `ef_search`
  candidates, and every row the filter rejects is simply gone. A tenant sharing
  the index with a much larger one could get a short list — or nothing —
  with no way to tell that apart from "there are no matches".

  `KilnCMS.Repo` sets `hnsw.iterative_scan = strict_order` on every connection,
  so a filtered scan resumes until it has the requested `limit` or hits
  `hnsw.max_scan_tuples`. That makes recall good, **not guaranteed**: at the
  scan-tuple ceiling the result is still a short list. So treat this as
  "the best matches we found", never as "all the matches that exist" —
  near-duplicate detection in particular must not be read as exhaustive.
  """
  alias KilnCMS.Search.BlockEmbedding

  @doc """
  Search blocks by semantic similarity.

  Options: `:block_type` (facet to one type), `:limit` (default 10), `:org_id`
  (tenant — scopes results to one org, epic #336; `nil` spans all orgs under
  `global?: true`).
  Returns `BlockEmbedding` rows nearest first; `[]` if semantic search is off.
  """
  @spec search(String.t(), keyword()) :: [BlockEmbedding.t()]
  def search(query, opts \\ []) when is_binary(query) do
    BlockEmbedding
    |> Ash.Query.for_read(:nearest, %{
      query: query,
      block_type: opts[:block_type],
      limit: opts[:limit] || 10
    })
    |> Ash.read!(authorize?: false, tenant: opts[:org_id])
  end
end
