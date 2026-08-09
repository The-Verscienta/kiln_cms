defmodule KilnCMS.StubEmbedder do
  @moduledoc """
  Deterministic embedding stub for tests: same text → same 384-d vector (so
  identical block text means cosine distance 0), no model loaded. Enable per
  suite (async: false — it swaps global app env) with:

      Application.put_env(:kiln_cms, KilnCMS.Search,
        Keyword.merge(original, KilnCMS.StubEmbedder.search_env()))

  Several older suites still carry private copies of this module — new tests
  should use this one.
  """

  @doc """
  The `KilnCMS.Search` settings a suite needs to run on this stub.

  More than `semantic:` + `embedder:`, and the extra is the point. Distances
  here come from `:erlang.phash2/1`, so they are deterministic but *arbitrary*
  — two unrelated strings are as likely to be close as two related ones. Any
  code path with a relevance threshold therefore has to be neutralized, or the
  suite asserts on a hash.

  Today that is `suggest_tags/2`'s ceiling (#851). `2.0` admits everything:
  cosine distance is `1 - cos θ`, so 2 is its maximum. A suite that wants to
  test the ceiling itself sets its own value on top of this — see
  `KilnCMS.Search.RelatedTest`.

  Merge this rather than spelling the keys out per suite: the next threshold
  added to the search stack should break one list here, not four setups that
  each fail with an empty result and nothing naming the cause.
  """
  @spec search_env() :: keyword()
  def search_env,
    do: [semantic: true, embedder: __MODULE__, suggest_tags_threshold: 2.0]

  @behaviour KilnCMS.Search.Embedder

  @impl true
  def embed(text) do
    seed = :erlang.phash2(text)
    {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
  end
end
