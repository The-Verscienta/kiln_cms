defmodule KilnCMS.Search.Embedder.Bumblebee do
  @moduledoc """
  Local embeddings via a Bumblebee text-embedding `Nx.Serving`
  (`KilnCMS.Search.Serving`), which `KilnCMS.Application` starts only when
  semantic search is enabled. Embedding runs in-process — no data leaves the
  box.
  """
  @behaviour KilnCMS.Search.Embedder

  if KilnCMS.Search.ML.available?() do
    @impl true
    def embed(text) when is_binary(text) do
      %{embedding: tensor} = Nx.Serving.batched_run(KilnCMS.Search.Serving.name(), text)
      {:ok, Nx.to_flat_list(tensor)}
    rescue
      error -> {:error, error}
    end
  else
    # The lean build's answer. `{:error, _}` is what the behaviour already
    # documents and what `KilnCMS.Search.VectorCache` and the block indexer
    # already handle — a failed embed is not a crash, it is a search that falls
    # back to its keyword leg. Configuring `semantic: true` on a build with no
    # ML stack therefore degrades rather than breaking, and
    # `KilnCMS.Application` says so once at boot.
    @impl true
    def embed(text) when is_binary(text), do: {:error, KilnCMS.Search.ML.unavailable()}
  end
end
