defmodule KilnCMS.Search.MultilingualTest do
  @moduledoc """
  The multilingual-model knobs (`docs/semantic-search-plan.md`): configurable
  pooling for the serving, and asymmetric query/document instruction prefixes
  applied before the adapter. Defaults preserve the bge-small behaviour (CLS
  pooling, no prefix). Uses a capturing stub so no model loads.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use ExUnit.Case, async: false

  alias KilnCMS.Search

  # Records the exact text handed to the adapter, so we can assert prefixing.
  defmodule CapturingEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      send(self(), {:embedded, text})
      {:ok, List.duplicate(0.0, 384)}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(embedder: CapturingEmbedder)
    :ok
  end

  test "pooling defaults to CLS and is overridable for multilingual models" do
    assert Search.pooling() == :cls_token_pooling
    put_search_env(pooling: :mean_pooling)
    assert Search.pooling() == :mean_pooling
  end

  test "no prefix by default — query and document pass through unchanged" do
    Search.embed_query("otters")
    assert_received {:embedded, "otters"}

    Search.embed_document("otters and rivers")
    assert_received {:embedded, "otters and rivers"}
  end

  test "asymmetric prefixes are applied per side (e5-style)" do
    put_search_env(query_prefix: "query: ", document_prefix: "passage: ")

    Search.embed_query("otters")
    assert_received {:embedded, "query: otters"}

    Search.embed_document("otters and rivers")
    assert_received {:embedded, "passage: otters and rivers"}

    # The bare embed/1 stays prefix-free (used by tests / the stub path).
    Search.embed("raw")
    assert_received {:embedded, "raw"}
  end
end
