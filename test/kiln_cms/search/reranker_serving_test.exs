defmodule KilnCMS.Search.RerankerServingTest do
  @moduledoc """
  The reranker serving's two failure modes, without loading a real model.

  * **Every score 1.0.** A cross-encoder reranker has one output logit, and
    Bumblebee's text classification defaults to softmax — over one logit,
    always 1.0. `scores_function/1` picks sigmoid for that head, and
    `serving_options/1` is what `load/0` hands Bumblebee. The one test that
    loads the real model is `@tag :calibration`, excluded by default.
  * **A model that will not load.** `load/0` answers `{:error, _}` instead of
    raising, `children/1` turns that into no child and a reported error, and
    the adapter answers `{:error, _}` (warning, throttled) when no serving is
    running — so the application starts without a reranker and search keeps
    its fused order instead of crash-looping at boot.

  Like `KilnCMS.Search.MLTest`, the file defines a different suite on each leg:
  `KilnCMS.Search.ML.available?/0` is a compile-time constant.
  """
  # async: false — the ML leg sets BUMBLEBEE_* environment variables and the
  # global KilnCMS.Search config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  # `load/0` builds the serving with exactly these options, so this is where
  # "the computed scores_function reaches Bumblebee" is pinned without a model.
  describe "serving_options/1" do
    test "passes scores_function/1's choice for the model's head" do
      assert RerankerServing.serving_options(%{num_labels: 1})[:scores_function] == :sigmoid
      assert RerankerServing.serving_options(%{num_labels: 3})[:scores_function] == :softmax
    end

    test "keeps the compiled shape and the search defn options" do
      options = RerankerServing.serving_options(%{num_labels: 1})
      assert options[:compile] == [batch_size: 8, sequence_length: 512]
      assert options[:defn_options] == KilnCMS.Search.defn_options()
    end
  end

  # The boot decision `KilnCMS.Application` delegates to: a loaded model is a
  # serving child; a model that will not load is no child, a reported error,
  # and a status an operator can read — never a crashed boot.
  describe "children/1" do
    setup do
      RerankerServing.reset_status()
      on_exit(&RerankerServing.reset_status/0)
      :ok
    end

    test "a loaded model is one serving child under the registered name" do
      assert [{Nx.Serving, opts}] = RerankerServing.children({:ok, :a_serving})
      assert opts[:serving] == :a_serving
      assert opts[:name] == RerankerServing.name()
      assert RerankerServing.status() == :running
    end

    test "a model that will not load is no child, reported, and visible in status/0" do
      log =
        capture_log(fn ->
          assert RerankerServing.children({:error, :enoent}) == []
        end)

      assert log =~ "could not be loaded"
      assert log =~ KilnCMS.Search.rerank_model()
      assert RerankerServing.status() == {:unavailable, ":enoent"}
    end

    test "is :off until a boot decided otherwise" do
      assert RerankerServing.status() == :off
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

      # The real model, from the local Bumblebee cache (downloads on first
      # run). Excluded by default like every calibration test: it needs the
      # weights. Pins the whole path — load/0 → serving → adapter — returning
      # a relevance, not 1.0 for every pair.
      @tag :calibration
      test "the default model scores a relevant pair high and an irrelevant one low" do
        assert {:ok, serving} = RerankerServing.load()
        start_supervised!({Nx.Serving, serving: serving, name: RerankerServing.name()})

        assert {:ok, [relevant, irrelevant]} =
                 Reranker.Bumblebee.scores("intensely bitter and cold", [
                   "Huang Lian: clears heat and dries dampness; intensely bitter and cold",
                   "Zusanli, an acupuncture point below the knee"
                 ])

        assert relevant > 0.5
        assert irrelevant < 0.1
      end

      test "the adapter answers {:error, _} when no reranker serving is running" do
        # Reranking is off in test, so `KilnCMS.Application` started no serving:
        # the state a deployment is left in after a failed load. An exit from
        # `Nx.Serving.batched_run/2`, which a bare `rescue` would not catch.
        Reranker.Bumblebee.reset_log_throttle()
        refute Process.whereis(RerankerServing.name())

        capture_log(fn ->
          assert {:error, {:exit, _reason}} = Reranker.Bumblebee.scores("query", ["a", "b"])
        end)
      end

      test "a failing reranker warns at most once a minute, without the query" do
        Reranker.Bumblebee.reset_log_throttle()

        log =
          capture_log(fn ->
            for _ <- 1..3, do: Reranker.Bumblebee.scores("secret question", ["secret doc"])
          end)

        assert log =~ "reranker failed (:noproc)"
        assert length(String.split(log, "reranker failed")) == 2
        refute log =~ "secret"
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
