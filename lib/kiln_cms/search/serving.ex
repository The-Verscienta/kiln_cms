defmodule KilnCMS.Search.Serving do
  @moduledoc """
  Builds the Bumblebee text-embedding `Nx.Serving` used for semantic search.

  `KilnCMS.Application` adds `{Nx.Serving, serving: build(), name: name(), ...}`
  to the supervision tree only when semantic search is enabled with the
  Bumblebee adapter — loading the model is expensive, so the default install
  skips it entirely.

  The model (`BAAI/bge-small-en-v1.5` by default) is a BERT encoder; embeddings
  use CLS-token pooling with L2 normalization, matching how the bge family is
  meant to be used.
  """
  @name __MODULE__

  @doc "Registered process name of the serving."
  @spec name() :: atom()
  def name, do: @name

  @doc """
  Build the text-embedding serving. Loads the model + tokenizer from the Hugging
  Face cache (downloading on first use), so this is slow and only called at
  supervisor start.
  """
  @spec build() :: Nx.Serving.t()
  def build do
    model = KilnCMS.Search.model()

    {:ok, model_info} = Bumblebee.load_model({:hf, model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model})

    Bumblebee.Text.text_embedding(model_info, tokenizer,
      compile: [batch_size: 8, sequence_length: 512],
      defn_options: KilnCMS.Search.defn_options(),
      output_attribute: :hidden_state,
      output_pool: :cls_token_pooling,
      embedding_processor: :l2_norm
    )
  end
end
