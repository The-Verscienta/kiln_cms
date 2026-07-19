defmodule KilnCMS.Search.BlockSearch do
  @moduledoc """
  Block-granular semantic search (Kiln v2 — decision D16).

  `search/2` returns the nearest blocks to a query by cosine distance, optionally
  faceted by `:block_type` — the "find the relevant section" query. Keyword/RRF
  fusion over a block-level tsvector is a documented follow-up; this is the
  semantic + faceting core.
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
