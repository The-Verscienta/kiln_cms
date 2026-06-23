defmodule KilnCMS.Search.Embedder.Bumblebee do
  @moduledoc """
  Local embeddings via a Bumblebee text-embedding `Nx.Serving`
  (`KilnCMS.Search.Serving`), which `KilnCMS.Application` starts only when
  semantic search is enabled. Embedding runs in-process — no data leaves the
  box.
  """
  @behaviour KilnCMS.Search.Embedder

  @impl true
  def embed(text) when is_binary(text) do
    %{embedding: tensor} = Nx.Serving.batched_run(KilnCMS.Search.Serving.name(), text)
    {:ok, Nx.to_flat_list(tensor)}
  rescue
    error -> {:error, error}
  end
end
