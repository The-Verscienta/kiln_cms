defmodule KilnCMS.Search.Reranker.Bumblebee do
  @moduledoc """
  Local cross-encoder reranker (e.g. `BAAI/bge-reranker-base`) via a Bumblebee
  text-classification `Nx.Serving` (`KilnCMS.Search.RerankerServing`), started
  only when some scope reranks — `KilnCMS.Search.rerank?/0` for every surface,
  `KilnCMS.Ask.rerank?/0` for the ask path alone.

  **Experimental.** Cross-encoder scoring depends on the exact model's output
  head: the serving reads a single-logit head as a sigmoid relevance (see
  `KilnCMS.Search.RerankerServing.scores_function/1`). Validate the scores
  against your chosen reranker before relying on the ordering in production.
  The hybrid integration and fallback are fully tested with a stub; this
  adapter's model path is not exercised in CI.
  """
  @behaviour KilnCMS.Search.Reranker

  if KilnCMS.Search.ML.available?() do
    require Logger

    @impl true
    def scores(query, docs) when is_binary(query) and is_list(docs) do
      results =
        KilnCMS.Search.RerankerServing.name()
        |> Nx.Serving.batched_run(Enum.map(docs, &{query, &1}))
        |> List.wrap()

      {:ok, Enum.map(results, &top_score/1)}
    rescue
      error -> failed({:error, error}, inspect(error.__struct__))
    catch
      # No serving registered — `KilnCMS.Application` started none because the
      # model would not load (see `KilnCMS.Search.RerankerServing`) — is an
      # exit from `Nx.Serving.batched_run/2`, not an exception. Same answer as
      # any other failure: `{:error, _}`, and the caller keeps its fused order.
      :exit, reason -> failed({:error, {:exit, reason}}, exit_kind(reason))
    end

    # A reranker that fails on every request would otherwise be silent: the
    # caller keeps its fused order and says nothing. Warn, at most once a
    # minute. Only the failure's *kind* is logged — an exit reason carries the
    # serving's input, which is the visitor's query and the candidates' text.
    @log_every_ms :timer.minutes(1)
    @log_key {__MODULE__, :last_failure_log}

    defp failed(error, kind) do
      now = System.monotonic_time(:millisecond)
      last = :persistent_term.get(@log_key, nil)

      if is_nil(last) or now - last >= @log_every_ms do
        :persistent_term.put(@log_key, now)

        Logger.warning(
          "reranker failed (#{kind}); keeping the fused order " <>
            "(KilnCMS.Search.RerankerServing.status/0 says whether it ever started)"
        )
      end

      error
    end

    # Atoms only: a crash reason can carry the input it crashed on.
    defp exit_kind({reason, {Nx.Serving, _fun, _args}}) when is_atom(reason), do: inspect(reason)
    defp exit_kind(reason) when is_atom(reason), do: inspect(reason)
    defp exit_kind(_reason), do: "serving exit"

    @doc false
    # Tests only: start from a known throttle state.
    def reset_log_throttle, do: :persistent_term.erase(@log_key)

    defp top_score(%{predictions: [%{score: score} | _]}), do: score
    defp top_score(_), do: 0.0
  else
    # As in the embedder: `{:error, _}` is the documented shape, and
    # `KilnCMS.Search.hybrid/3` already keeps the fused order when reranking
    # fails.
    @impl true
    def scores(query, docs) when is_binary(query) and is_list(docs),
      do: {:error, KilnCMS.Search.ML.unavailable()}
  end
end
