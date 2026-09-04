defmodule KilnCMS.Search.RerankerServing do
  @moduledoc """
  Bumblebee text-classification `Nx.Serving` used as a cross-encoder reranker.
  `KilnCMS.Application` starts it only when some scope reranks — every
  surface (`KilnCMS.Search.rerank?/0`) or `/api/ask` alone
  (`KilnCMS.Ask.rerank?/0`) — with the Bumblebee reranker; loading the model
  is expensive.
  """
  @name __MODULE__

  @doc "Registered process name of the serving."
  @spec name() :: atom()
  def name, do: @name

  @doc "Build the reranker serving (loads model + tokenizer)."
  @spec build() :: Nx.Serving.t()
  def build do
    model = KilnCMS.Search.rerank_model()
    {:ok, model_info} = Bumblebee.load_model({:hf, model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model})

    Bumblebee.Text.text_classification(model_info, tokenizer,
      compile: [batch_size: 8, sequence_length: 512],
      defn_options: KilnCMS.Search.defn_options()
    )
  end
end
