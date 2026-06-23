defmodule KilnCMS.Search do
  @moduledoc """
  Semantic / hybrid search facade and config access.

  All knobs live under `config :kiln_cms, KilnCMS.Search` (see
  `docs/semantic-search-plan.md`). With `semantic: false` (the default) the
  embedding model never loads and content writes skip embedding work, so the
  default install pays nothing.
  """

  @doc "Whether semantic search is enabled."
  @spec semantic?() :: boolean()
  def semantic?, do: cfg(:semantic, false)

  @doc "The configured embedder adapter module."
  @spec embedder() :: module()
  def embedder, do: cfg(:embedder, KilnCMS.Search.Embedder.Bumblebee)

  @doc "Hugging Face model id used for embeddings."
  @spec model() :: String.t()
  def model, do: cfg(:model, "BAAI/bge-small-en-v1.5")

  @doc "Embedding vector dimension (must match the model)."
  @spec dim() :: pos_integer()
  def dim, do: cfg(:dim, 384)

  @doc "Embed a single string into a list of floats via the active adapter."
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text), do: embedder().embed(text)

  defp cfg(key, default) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
