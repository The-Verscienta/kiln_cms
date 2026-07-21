defmodule KilnCMS.Search.ServingShapeTest do
  @moduledoc """
  The embedding serving's compiled shape (`batch_size` × `sequence_length`).
  Inputs are padded to that shape, so it — not the real input length — is what
  each embedding costs; both knobs are configurable for installs that serve
  interactive queries rather than bulk indexing. Defaults preserve the
  previously hardcoded 8 × 512. Config-only, so no model loads here.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use ExUnit.Case, async: false

  alias KilnCMS.Search

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    :ok
  end

  test "defaults match the shape that was previously hardcoded" do
    assert Search.batch_size() == 8
    assert Search.sequence_length() == 512
  end

  test "batch size is overridable for one-query-at-a-time servings" do
    put_search_env(batch_size: 1)
    assert Search.batch_size() == 1
  end

  test "sequence length takes a single value or a bucket list" do
    put_search_env(sequence_length: 128)
    assert Search.sequence_length() == 128

    # Bumblebee compiles one computation per bucket and routes each input to
    # the smallest that fits, so short queries skip the padding they don't
    # need while long documents keep the full window.
    put_search_env(sequence_length: [64, 128, 512])
    assert Search.sequence_length() == [64, 128, 512]
  end
end
