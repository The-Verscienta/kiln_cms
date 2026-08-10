defmodule KilnCMS.Search.TagSuggestionCalibrationTest do
  @moduledoc """
  What `:suggest_tags_threshold` actually does, at the value we ship (#1086).

  Two halves, and the split is the point. #851 shipped the ceiling with a
  derived number and every test in the suite had to neutralise it — the stub
  embedder's hash-seeded vectors cannot tell a good suggestion from a bad one —
  so the one constant the feature turns on was exercised by nothing.

    * The tests below run always. They read `KilnCMS.TagSuggestionCorpus`'s
      **recorded** distances, so they need no model, and they fail if the
      configured default drifts into either failure mode: an empty panel, or a
      panel full of tags nobody would tick.
    * `@tag :calibration` re-measures from the same corpus with the real
      embedder. Excluded by default because it downloads a model and takes
      minutes; it is how the recorded numbers were produced and how to produce
      them again for a different model.

  Neither half asserts that any particular tag is suggested for any particular
  document. That would pin the model, not the threshold, and the model is a
  config key.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search
  alias KilnCMS.TagSuggestionCorpus

  defp bands do
    Enum.split_with(TagSuggestionCorpus.distances(), fn {_doc, _tag, kind, _d} ->
      kind == :good
    end)
  end

  defp kept(rows, ceiling), do: Enum.count(rows, fn {_doc, _tag, _kind, d} -> d <= ceiling end)

  describe "the shipped default" do
    test "is a number cosine distance can actually produce" do
      threshold = Search.suggest_tags_threshold()

      # Not pedantry. `nil` is the natural thing for an operator to copy from
      # `:semantic_max_distance` three lines above it in config, and Erlang
      # orders `number < atom`, so `0.9 <= nil` is true and a `nil` ceiling
      # admits everything — silently restoring #851.
      assert is_number(threshold)
      assert threshold > 0 and threshold <= 2.0
    end

    # The failure #1086 predicted, and the one the shipped 0.25 actually had:
    # 3 of 27 wanted tags survive, so the panel is empty for most documents and
    # an editor reads that as broken rather than as "nothing is close".
    test "keeps most of the tags a human would tick" do
      {good, _bad} = bands()
      kept = kept(good, Search.suggest_tags_threshold())

      assert kept / length(good) >= 0.7,
             "the ceiling keeps only #{kept} of #{length(good)} wanted tags — " <>
               "the suggestion panel is empty for most documents"
    end

    # The opposite failure: the panel offers "carburetors" for a page about
    # herbal tea, beside a real match, at the same size.
    test "admits few of the tags a human would not" do
      {_good, bad} = bands()
      kept = kept(bad, Search.suggest_tags_threshold())

      assert kept / length(bad) <= 0.1,
             "the ceiling admits #{kept} of #{length(bad)} unwanted tags"
    end

    # `suggest_tags/2` takes the five closest under the ceiling. If the ceiling
    # routinely admits more than that, the LIMIT is doing the filtering and the
    # ceiling has stopped being the thing that decides.
    test "leaves the ceiling, not the limit, deciding what is shown" do
      threshold = Search.suggest_tags_threshold()
      documents = TagSuggestionCorpus.documents()

      admitted = kept(TagSuggestionCorpus.distances(), threshold) / length(documents)

      assert admitted <= 5.0,
             "#{Float.round(admitted, 2)} tags per document clear the ceiling, " <>
               "so `limit: 5` is what filters and the ceiling is decoration"
    end
  end

  describe "the recorded measurement" do
    test "covers every document against the whole vocabulary" do
      documents = TagSuggestionCorpus.documents()
      vocabulary = TagSuggestionCorpus.vocabulary()

      assert length(TagSuggestionCorpus.distances()) == length(documents) * length(vocabulary)
    end

    # The finding #1086 was filed to establish. If a re-measurement ever shows
    # a clean separation, the ceiling stops being a judgement call and this
    # test should be deleted along with the prose that leans on it.
    test "shows the two bands overlapping" do
      {good, bad} = bands()

      worst_good = good |> Enum.map(&elem(&1, 3)) |> Enum.max()
      best_bad = bad |> Enum.map(&elem(&1, 3)) |> Enum.min()

      assert best_bad < worst_good,
             "the bands no longer overlap — a ceiling between #{best_bad} and " <>
               "#{worst_good} would be exactly right, and the docs still say otherwise"
    end
  end

  # ── the harness ─────────────────────────────────────────────────────────────

  @tag :calibration
  @tag timeout: :timer.minutes(30)
  test "re-measure the corpus against the configured embedder" do
    model = Search.model()
    IO.puts("\n#{model} — loading (downloads on first run)…")

    {:ok, model_info} = Bumblebee.load_model({:hf, model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model})

    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        compile: [batch_size: 8, sequence_length: 512],
        defn_options: Search.defn_options(),
        output_attribute: :hidden_state,
        output_pool: Search.pooling(),
        embedding_processor: :l2_norm
      )

    embed = fn text ->
      %{embedding: t} = Nx.Serving.run(serving, Search.document_prefix() <> text)
      Nx.to_flat_list(t)
    end

    vocabulary = TagSuggestionCorpus.vocabulary()
    tag_vectors = Map.new(vocabulary, &{&1, embed.(&1)})

    rows =
      Enum.flat_map(TagSuggestionCorpus.documents(), fn {title, blocks, wanted} ->
        # The MEAN of per-block embeddings, because that is what
        # `Related.centroid/1` computes from stored `BlockEmbedding` rows.
        centroid = blocks |> Enum.map(embed) |> mean()

        Enum.map(vocabulary, fn tag ->
          {title, tag, if(tag in wanted, do: :good, else: :bad),
           cosine_distance(centroid, Map.fetch!(tag_vectors, tag))}
        end)
      end)

    report(rows, vocabulary)

    # An assertion, so this is a test rather than a script: the corpus has to be
    # separable at all, or the labels are wrong and no ceiling would help.
    {good, bad} = Enum.split_with(rows, &(elem(&1, 2) == :good))
    assert Enum.min(Enum.map(good, &elem(&1, 3))) < Enum.min(Enum.map(bad, &elem(&1, 3)))
  end

  defp report(rows, vocabulary) do
    f = &:erlang.float_to_binary(&1, decimals: 4)
    {good, bad} = Enum.split_with(rows, &(elem(&1, 2) == :good))
    documents = TagSuggestionCorpus.documents()

    for {title, _blocks, wanted} <- documents do
      IO.puts("\n#{title}   (wanted: #{Enum.join(wanted, ", ")})")

      rows
      |> Enum.filter(&(elem(&1, 0) == title))
      |> Enum.sort_by(&elem(&1, 3))
      |> Enum.take(6)
      |> Enum.each(fn {_doc, tag, kind, d} ->
        IO.puts("  #{f.(d)}  #{String.pad_trailing(tag, 16)} #{kind}")
      end)
    end

    IO.puts("\n#{length(documents)} documents x #{length(vocabulary)} tags")
    IO.puts("wanted     #{f.(min_of(good))} - #{f.(max_of(good))}   (#{length(good)} pairs)")
    IO.puts("not wanted #{f.(min_of(bad))} - #{f.(max_of(bad))}   (#{length(bad)} pairs)")
    IO.puts("\nceiling   wanted kept    unwanted admitted   per document")

    for t <- [0.25, 0.30, 0.32, 0.35, 0.38, 0.40, 0.45, 0.50] do
      kg = kept(good, t)
      kb = kept(bad, t)

      IO.puts(
        "#{f.(t)}    #{String.pad_trailing("#{kg}/#{length(good)}", 14)} " <>
          "#{String.pad_trailing("#{kb}/#{length(bad)}", 19)} " <>
          "#{Float.round((kg + kb) / length(documents), 2)}"
      )
    end

    IO.puts("\nshipping #{f.(Search.suggest_tags_threshold())}")
  end

  defp min_of(rows), do: rows |> Enum.map(&elem(&1, 3)) |> Enum.min()
  defp max_of(rows), do: rows |> Enum.map(&elem(&1, 3)) |> Enum.max()

  defp mean(vectors) do
    count = length(vectors)
    vectors |> Enum.zip_with(& &1) |> Enum.map(&(Enum.sum(&1) / count))
  end

  # `Related.cosine_distance/2`'s arithmetic, restated here rather than made
  # public: this measures the metric, so borrowing the implementation would let
  # a change to it move the measurement without anything noticing.
  defp cosine_distance(a, b) do
    dot = a |> Enum.zip_with(b, &*/2) |> Enum.sum()

    norm =
      :math.sqrt(Enum.sum(Enum.map(a, &(&1 * &1)))) *
        :math.sqrt(Enum.sum(Enum.map(b, &(&1 * &1))))

    if norm == 0.0, do: 1.0, else: 1.0 - dot / norm
  end
end
