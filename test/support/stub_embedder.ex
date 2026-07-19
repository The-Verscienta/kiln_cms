defmodule KilnCMS.StubEmbedder do
  @moduledoc """
  Deterministic embedding stub for tests: same text → same 384-d vector (so
  identical block text means cosine distance 0), no model loaded. Enable per
  suite (async: false — it swaps global app env) with:

      Application.put_env(:kiln_cms, KilnCMS.Search,
        Keyword.merge(original, semantic: true, embedder: KilnCMS.StubEmbedder))

  Several older suites still carry private copies of this module — new tests
  should use this one.
  """
  @behaviour KilnCMS.Search.Embedder

  @impl true
  def embed(text) do
    seed = :erlang.phash2(text)
    {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
  end
end
