defmodule KilnCMS.Search.MLTest do
  @moduledoc """
  What a build without the optional ML stack actually does (#1321).

  The file defines a **different suite on each leg** — the lean default that
  every CI job but one compiles, and the `ml` job that compiles Bumblebee/Nx/
  EXLA in. That is not a stylistic choice: `KilnCMS.Search.ML.available?/0` is a
  compile-time constant, so a runtime `if` on it is a dead branch the type
  checker rejects (see that module). Branching in the module body means each leg
  compiles only the assertions that mean something there, and the `describe`
  name in the output says which leg ran.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search.Embedder
  alias KilnCMS.Search.ML
  alias KilnCMS.Search.Reranker

  test "available?/0 answers for the deps that are actually loadable" do
    assert ML.available?() == (Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx.Serving))
  end

  test "the configured adapters exist on either leg" do
    # The config default does not change with the flag — a lean build still
    # names the Bumblebee adapters, and they still exist. That is what keeps the
    # degradation a runtime `{:error, _}` rather than an UndefinedFunctionError
    # out of `KilnCMS.Search.embed/1`.
    assert KilnCMS.Search.embedder() == Embedder.Bumblebee
    assert KilnCMS.Search.reranker() == Reranker.Bumblebee
    assert function_exported?(Embedder.Bumblebee, :embed, 1)
    assert function_exported?(Reranker.Bumblebee, :scores, 2)
  end

  if ML.available?() do
    describe "with the ML stack compiled in (KILN_ML)" do
      test "the real shape compiled, not the stub" do
        # No model is loaded and no inference runs here — that is
        # `@tag :calibration`'s job, and it is excluded everywhere. What this
        # leg uniquely proves is that the Bumblebee/Nx call sites still
        # COMPILE, which the lean legs cannot notice going stale.
        assert Code.ensure_loaded?(Nx.Serving)
        assert function_exported?(KilnCMS.Search.Serving, :build, 0)
        assert function_exported?(KilnCMS.Search.RerankerServing, :build, 0)
      end

      test "defn_options picks the EXLA compiler" do
        # `:exla` is `only: [:dev, :test]` inside the opt-in, so on this leg it
        # is present and this is the branch that runs in anger.
        assert KilnCMS.Search.defn_options() == [compiler: EXLA]
      end
    end
  else
    describe "without the ML stack (the default build)" do
      test "the embedder degrades instead of crashing" do
        # `{:error, term()}` is the shape `KilnCMS.Search.Embedder` documents,
        # so `VectorCache.embed_now/1` and the block indexer already treat this
        # as "no vector" and let search fall back to its keyword legs.
        assert {:error, %ML.NotCompiledError{} = error} = Embedder.Bumblebee.embed("hello")
        assert Exception.message(error) =~ "KILN_ML=1"
      end

      test "the reranker degrades instead of crashing" do
        assert {:error, %ML.NotCompiledError{}} = Reranker.Bumblebee.scores("query", ["a", "b"])
      end

      test "building a serving raises rather than returning a stub" do
        # Unreachable through `KilnCMS.Application`, which adds no serving child
        # to a lean build. It raises so a future caller that forgets the gate
        # fails where the mistake is, not at the first `batched_run`.
        assert_raise ML.NotCompiledError, fn -> KilnCMS.Search.Serving.build() end
        assert_raise ML.NotCompiledError, fn -> KilnCMS.Search.RerankerServing.build() end
      end

      test "defn_options is empty, so nothing asks for a compiler that is absent" do
        assert KilnCMS.Search.defn_options() == []
      end
    end
  end
end
