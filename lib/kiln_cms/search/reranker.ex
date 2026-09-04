defmodule KilnCMS.Search.Reranker do
  @moduledoc """
  Behaviour for reranking search results: given a query and candidate document
  texts, return a relevance score per document (higher = more relevant). Used as
  an optional final stage of `KilnCMS.Search.hybrid/3` (`rerank: true`).

  The active implementation comes from `config :kiln_cms, KilnCMS.Search,
  reranker: ...`. Reranking is off by default, and has two scopes:
  `KilnCMS.Search`'s `rerank: true` reranks every search surface,
  `KilnCMS.Ask`'s `rerank: true` only the `/api/ask` path (a bounded,
  per-question cost). The
  default adapter (`KilnCMS.Search.Reranker.Bumblebee`, a local cross-encoder)
  only loads when one of them is on. Tests inject a deterministic stub.
  """
  @callback scores(query :: String.t(), docs :: [String.t()]) ::
              {:ok, [float()]} | {:error, term()}
end
