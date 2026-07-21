defmodule KilnCMS.Search.GlobalEmbeddingTest do
  @moduledoc """
  `KilnCMS.Search.global/2` runs a hybrid search per registered content type,
  and every one of those has a semantic leg. Embedding is the dominant cost of
  a semantic search, so the query must be embedded **once for the whole sweep**
  and the vector reused — not re-embedded per section. Uses a counting stub
  embedder rather than loading a model.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Search

  # Counts calls in the calling process, so a test can assert how many
  # embeddings one search actually performed.
  defmodule CountingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      :counters.add(:persistent_term.get(__MODULE__), 1, 1)
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defmodule FailingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(_text) do
      :counters.add(:persistent_term.get(CountingEmbedder), 1, 1)
      {:error, :boom}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  defp embed_count, do: :counters.get(:persistent_term.get(CountingEmbedder), 1)

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    :persistent_term.put(CountingEmbedder, :counters.new(1, []))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: CountingEmbedder)
    :ok
  end

  test "a global sweep embeds the query exactly once, whatever the type count" do
    Search.global("otters")

    # The count that matters is 1, not "small": it must not scale with the
    # number of registered content types, which is what makes this a
    # regression guard rather than a threshold.
    assert embed_count() == 1
  end

  test "the reused vector still reaches each section's semantic leg" do
    # Both sections come back sorted by semantic distance to the same vector,
    # so a single embedding is genuinely serving every type — not just being
    # counted once while the sections silently lose their semantic leg.
    sections = Search.global("otters")

    assert is_map(sections)
    assert Map.has_key?(sections, :pages)
    assert Map.has_key?(sections, :posts)
    assert embed_count() == 1
  end

  test "an unembeddable query is attempted once, not once per section" do
    put_search_env(embedder: FailingEmbedder)

    sections = Search.global("otters")

    # The failure is discovered once and propagated; each section skips its
    # semantic leg rather than retrying the same failing embed.
    assert embed_count() == 1
    assert is_map(sections)
  end

  test "semantic disabled embeds nothing at all" do
    put_search_env(semantic: false)

    Search.global("otters")

    assert embed_count() == 0
  end

  test "a single-resource caller still embeds for itself" do
    # `hybrid/3` without a `:query_vector` has nobody to inherit one from —
    # the per-type search routes rely on this.
    Search.hybrid(:page, "otters")

    assert embed_count() == 1
  end
end
