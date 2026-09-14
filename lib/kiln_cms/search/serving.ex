defmodule KilnCMS.Search.Serving do
  @moduledoc """
  Builds the Bumblebee text-embedding `Nx.Serving` used for semantic search.

  `KilnCMS.Application` adds `{Nx.Serving, serving: build(), name: name(), ...}`
  to the supervision tree only when semantic search is enabled with the
  Bumblebee adapter — loading the model is expensive, so the default install
  skips it entirely.

  The model (`BAAI/bge-small-en-v1.5` by default) is a BERT encoder; embeddings
  use L2 normalization and the configured `pooling` (`:cls_token_pooling` for
  the bge family, `:mean_pooling` for multilingual MiniLM / e5), matching how
  the chosen model was trained. See `docs/semantic-search-plan.md` for the
  multilingual model recipe.

  The compiled shape is `KilnCMS.Search.batch_size/0` ×
  `KilnCMS.Search.sequence_length/0`. Inputs are padded to it, so that shape —
  not the real input size — is what each embedding costs; installs that serve
  interactive queries should read both docs before keeping the defaults.
  """
  @name __MODULE__

  @doc "Registered process name of the serving."
  @spec name() :: atom()
  def name, do: @name

  # Compiled one way or the other — see `KilnCMS.Search.ML`. Naming
  # `Bumblebee.load_model/1` in a build without the dep is a compile *warning*,
  # which `--warnings-as-errors` makes a compile failure, so the lean build must
  # not contain this body at all.
  if KilnCMS.Search.ML.available?() do
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
        compile: [
          batch_size: KilnCMS.Search.batch_size(),
          sequence_length: KilnCMS.Search.sequence_length()
        ],
        defn_options: KilnCMS.Search.defn_options(),
        output_attribute: :hidden_state,
        output_pool: KilnCMS.Search.pooling(),
        embedding_processor: :l2_norm
      )
    end
  else
    @doc """
    Raises: this build has no ML stack, so there is no serving to build.

    Unreachable in practice — `KilnCMS.Application` does not add an embedding
    child to the supervision tree in a lean build. It raises rather than
    returning a stub so that a future caller which forgets that gate fails
    where the mistake is, rather than at the first `batched_run`.
    """
    @spec build() :: no_return()
    def build, do: KilnCMS.Search.ML.unavailable!()
  end
end
