defmodule KilnCMS.Search.RerankerServing do
  @moduledoc """
  Bumblebee text-classification `Nx.Serving` used as a cross-encoder reranker.
  `KilnCMS.Application` starts it only when some scope reranks — every
  surface (`KilnCMS.Search.rerank?/0`) or `/api/ask` alone
  (`KilnCMS.Ask.rerank?/0`) — with the Bumblebee reranker; loading the model
  is expensive.

  ## Scores

  A cross-encoder reranker has a **single-logit** head: `num_labels` is 1 and
  the one logit is the relevance. Bumblebee's text classification defaults to
  `scores_function: :softmax`, and softmax over one logit is exactly 1.0 —
  every pair scored 1.0, so a "reranked" section kept its fused order while
  every hit's score became 1.0, and anything sorting hits across sections by
  score (the `/api/ask` source list, a front end merging sections) fell back
  to section order. `scores_function/1` picks `:sigmoid` for a single-logit
  head instead: the same order as the raw logit, as a 0–1 relevance that
  compares across sections. A head with more than one label is not a
  relevance score this module knows how to read; it keeps softmax and is
  warned about once at load.

  ## A model that will not load

  `load/0` returns `{:error, reason}` rather than raising, and `children/1`
  turns that into no serving child plus a `KilnCMS.Config.Report.error/3`
  (log and Sentry). A reranker is a refinement: without it every search keeps
  its fused order (`KilnCMS.Search.Reranker.Bumblebee` answers `{:error, _}`,
  which `hybrid/3` already treats as "keep the fused order"). Raising here
  used to take the whole application down at boot, so a deployment that
  switched reranking on without the model in its cache (an offline image,
  `BUMBLEBEE_OFFLINE=true`) crash-looped instead of searching without it.

  `status/0` answers whether this node is reranking, for an operator after
  boot:

      bin/kiln_cms rpc 'KilnCMS.Search.RerankerServing.status() |> IO.inspect()'
  """
  @name __MODULE__
  @status_key {__MODULE__, :status}

  @doc "Registered process name of the serving."
  @spec name() :: atom()
  def name, do: @name

  @doc """
  Whether this node is reranking: `:off` (no scope reranks, or the reranker is
  not the Bumblebee adapter), `:running`, or `{:unavailable, reason}` when
  reranking is switched on but the model could not be loaded at boot.

  `:running` means the loaded serving was handed to the supervisor at boot,
  not that the serving process is alive now. A serving that later fails shows
  up as the adapter's throttled "reranker failed" warning.
  """
  @spec status() :: :off | :running | {:unavailable, String.t()}
  def status, do: :persistent_term.get(@status_key, :off)

  @doc false
  # Tests only: forget a status a previous test recorded.
  def reset_status, do: :persistent_term.erase(@status_key)

  @doc """
  The options the serving is built with for a model whose spec is `spec`:
  the compiled shape, the defn options and `scores_function/1`'s choice.
  """
  @spec serving_options(map()) :: keyword()
  def serving_options(spec) do
    [
      compile: [batch_size: 8, sequence_length: 512],
      defn_options: KilnCMS.Search.defn_options(),
      scores_function: scores_function(spec)
    ]
  end

  @doc """
  The supervision children for a `load/0` result.

  `{:ok, serving}` is the serving, registered under `name/0`. `{:error,
  reason}` is **no** child: the application starts without a reranker, the
  failure is reported once through `KilnCMS.Config.Report.error/3`, and
  `status/0` answers `{:unavailable, reason}` from then on.
  """
  @spec children({:ok, term()} | {:error, term()}) :: [
          Supervisor.child_spec() | {module(), keyword()}
        ]
  def children({:ok, serving}) do
    :persistent_term.put(@status_key, :running)
    [{Nx.Serving, serving: serving, name: @name, batch_timeout: 50}]
  end

  def children({:error, reason}) do
    model = KilnCMS.Search.rerank_model()
    summary = inspect(reason, limit: 5, printable_limit: 200)
    :persistent_term.put(@status_key, {:unavailable, summary})

    KilnCMS.Config.Report.error(
      "reranker_load",
      "Reranking is switched on (KilnCMS.Search rerank / KilnCMS.Ask rerank / ASK_RERANK) " <>
        "but the reranker model #{model} could not be loaded, so no reranker started and " <>
        "search keeps its fused order. Bake the model into the image (or allow the " <>
        "Hugging Face download) and restart.",
      %{model: model, reason: summary}
    )

    []
  end

  @doc """
  The Bumblebee `scores_function` for a reranker whose model spec is `spec`:
  `:sigmoid` for a single-logit cross-encoder head, `:softmax` otherwise.
  See "Scores" above.
  """
  @spec scores_function(map()) :: :sigmoid | :softmax
  def scores_function(%{num_labels: 1}), do: :sigmoid
  def scores_function(_spec), do: :softmax

  # Two shapes, for the reason `KilnCMS.Search.Serving` spells out.
  if KilnCMS.Search.ML.available?() do
    require Logger

    @doc """
    Load the configured reranker model and tokenizer and build its serving.
    `{:error, reason}` when either cannot be loaded — never raises.
    """
    @spec load() :: {:ok, Nx.Serving.t()} | {:error, term()}
    def load do
      model = KilnCMS.Search.rerank_model()

      with {:ok, model_info} <- Bumblebee.load_model({:hf, model}),
           {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, model}) do
        warn_unless_single_logit(model, model_info.spec)

        {:ok,
         Bumblebee.Text.text_classification(
           model_info,
           tokenizer,
           serving_options(model_info.spec)
         )}
      end
    rescue
      error -> {:error, error}
    end

    @doc "Build the reranker serving (loads model + tokenizer); raises when it cannot."
    @spec build() :: Nx.Serving.t()
    def build do
      case load() do
        {:ok, serving} ->
          serving

        {:error, reason} ->
          raise "could not load reranker model #{KilnCMS.Search.rerank_model()}: " <>
                  inspect(reason)
      end
    end

    defp warn_unless_single_logit(_model, %{num_labels: 1}), do: :ok

    defp warn_unless_single_logit(model, spec) do
      Logger.warning(
        "reranker model #{model} has #{inspect(Map.get(spec, :num_labels))} labels; " <>
          "Kiln reads a single-logit cross-encoder head, so its reranked order is not " <>
          "a relevance order"
      )
    end
  else
    @doc "Always `{:error, _}`: this build has no ML stack, so there is no model to load."
    @spec load() :: {:error, KilnCMS.Search.ML.NotCompiledError.t()}
    def load, do: {:error, KilnCMS.Search.ML.unavailable()}

    @doc "Raises: this build has no ML stack, so there is no serving to build."
    @spec build() :: no_return()
    def build, do: KilnCMS.Search.ML.unavailable!()
  end
end
