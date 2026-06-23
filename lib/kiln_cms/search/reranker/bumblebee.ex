defmodule KilnCMS.Search.Reranker.Bumblebee do
  @moduledoc """
  Local cross-encoder reranker (e.g. `BAAI/bge-reranker-base`) via a Bumblebee
  text-classification `Nx.Serving` (`KilnCMS.Search.RerankerServing`), started
  only when `rerank: true`.

  **Experimental.** Cross-encoder scoring depends on the exact model's output
  head; validate the scores against your chosen reranker before relying on the
  ordering in production. The hybrid integration and fallback are fully tested
  with a stub; this adapter's model path is not exercised in CI.
  """
  @behaviour KilnCMS.Search.Reranker

  @impl true
  def scores(query, docs) when is_binary(query) and is_list(docs) do
    results =
      KilnCMS.Search.RerankerServing.name()
      |> Nx.Serving.batched_run(Enum.map(docs, &{query, &1}))
      |> List.wrap()

    {:ok, Enum.map(results, &top_score/1)}
  rescue
    error -> {:error, error}
  end

  defp top_score(%{predictions: [%{score: score} | _]}), do: score
  defp top_score(_), do: 0.0
end
