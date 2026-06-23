defmodule KilnCMS.Search.Embedder do
  @moduledoc """
  Behaviour for turning text into an embedding vector.

  The active implementation is selected by
  `config :kiln_cms, KilnCMS.Search, embedder: ...` and reached via
  `KilnCMS.Search.embed/1`. The default is
  `KilnCMS.Search.Embedder.Bumblebee` (local, in-process). Tests inject a
  deterministic fake.
  """
  @callback embed(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
end
