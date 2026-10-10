defmodule KilnCMS.Search.RerankerServingTest do
  @moduledoc """
  The reranker serving's two failure modes, without loading a real model.

  * **Every score 1.0.** A cross-encoder reranker has one output logit, and
    Bumblebee's text classification defaults to softmax — over one logit,
    always 1.0. `scores_function/1` is what picks sigmoid for that head; the ML
    leg also pins the arithmetic that made the default wrong.
  * **A model that will not load.** `load/0` answers `{:error, _}` instead of
    raising, and the adapter answers `{:error, _}` when no serving is running,
    so `KilnCMS.Application` can start without a reranker and search keeps its
    fused order instead of the application crash-looping at boot.

  Like `KilnCMS.Search.MLTest`, the file defines a different suite on each leg:
  `KilnCMS.Search.ML.available?/0` is a compile-time constant.
  """
  # async: false — the ML leg sets BUMBLEBEE_* environment variables and the
  # global KilnCMS.Search config.
  use ExUnit.Case, async: false

  alias KilnCMS.Search.ML
  alias KilnCMS.Search.Reranker
  alias KilnCMS.Search.RerankerServing

  describe "scores_function/1" do
    test "reads a single-logit cross-encoder head as a sigmoid relevance" do
      assert RerankerServing.scores_function(%{num_labels: 1}) == :sigmoid
    end

    test "leaves any other head on softmax" do
      assert RerankerServing.scores_function(%{num_labels: 2}) == :softmax
      assert RerankerServing.scores_function(%{}) == :softmax
    end
  end

  if ML.available?() do
    describe "with the ML stack compiled in (KILN_ML)" do
      setup do
        original_search = Application.get_env(:kiln_cms, KilnCMS.Search)

        original_env =
          Map.new(~w(BUMBLEBEE_OFFLINE BUMBLEBEE_CACHE_DIR), &{&1, System.get_env(&1)})

        on_exit(fn ->
          Application.put_env(:kiln_cms, KilnCMS.Search, original_search)

          Enum.each(original_env, fn
            {name, nil} -> System.delete_env(name)
            {name, value} -> System.put_env(name, value)
          end)
        end)

        :ok
      end

      # The arithmetic behind the bug, on the logits bge-reranker-base gives
      # one relevant and one irrelevant pair: softmax across a single label
      # cannot tell them apart, sigmoid can.
      test "softmax over one logit is 1.0 whatever the logit; sigmoid is not" do
        logits = Nx.tensor([[4.67], [-8.14]])

        assert Nx.to_flat_list(Axon.Activations.softmax(logits)) == [1.0, 1.0]

        [relevant, irrelevant] = Nx.to_flat_list(Axon.Activations.sigmoid(logits))
        assert relevant > 0.99
        assert irrelevant < 0.001
      end

      test "load/0 answers {:error, _} for a model it cannot load, rather than raising" do
        # Offline against an empty cache: what an image without the reranker
        # baked in sees at boot. No network is touched.
        cache =
          Path.join(System.tmp_dir!(), "kiln-reranker-test-#{System.unique_integer([:positive])}")

        File.mkdir_p!(cache)
        on_exit(fn -> File.rm_rf!(cache) end)

        System.put_env("BUMBLEBEE_OFFLINE", "true")
        System.put_env("BUMBLEBEE_CACHE_DIR", cache)

        Application.put_env(
          :kiln_cms,
          KilnCMS.Search,
          Keyword.put(
            Application.get_env(:kiln_cms, KilnCMS.Search, []),
            :rerank_model,
            "kiln-test/no-such-reranker"
          )
        )

        assert {:error, _reason} = RerankerServing.load()
      end

      test "the adapter answers {:error, _} when no reranker serving is running" do
        # Reranking is off in test, so `KilnCMS.Application` started no serving:
        # the state a deployment is left in after a failed load. An exit from
        # `Nx.Serving.batched_run/2`, which a bare `rescue` would not catch.
        refute Process.whereis(RerankerServing.name())
        assert {:error, {:exit, _reason}} = Reranker.Bumblebee.scores("query", ["a", "b"])
      end
    end
  else
    describe "without the ML stack (the default build)" do
      test "load/0 answers {:error, _} instead of raising" do
        assert {:error, %ML.NotCompiledError{}} = RerankerServing.load()
      end
    end
  end
end
