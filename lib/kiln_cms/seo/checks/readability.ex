defmodule KilnCMS.Seo.Checks.Readability do
  @moduledoc """
  How hard the prose is to read: content length, sentence and paragraph
  length, and a Flesch reading-ease score.

  ## Locale honesty

  Sentence and paragraph length are language-neutral and always run. Flesch is
  **English only** — its syllable heuristic has no meaning elsewhere — and
  returns `:n_a` for other locales rather than emitting confidently wrong
  advice. Skipping is silent, not a warning.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @thin_content 300
  @long_sentence_words 25
  @long_sentence_ratio 0.25
  @long_paragraph_words 150
  # Below this the score swings wildly on one sentence.
  @flesch_floor_words 100
  @hard_to_read_below 50.0

  @impl Kiln.Advisory
  def check(%Context{body: body} = context) do
    [
      content_length(body),
      sentence_length(body),
      paragraph_length(body),
      flesch(body, Context.english?(context))
    ]
  end

  defp content_length(%{word_count: 0}), do: :n_a

  # The one finding here that is purely a search concern: a short page is
  # perfectly accessible. The other three — long sentences, long paragraphs,
  # hard-to-read prose — are WCAG 3.1.5 territory as much as SEO advice, so
  # they take the check's default and show in both panels (#495).
  defp content_length(%{word_count: count}) when count < @thin_content,
    do:
      :warning
      |> finding(:thin_content, :body, %{count: count, min: @thin_content})
      |> lensed([:seo])

  defp content_length(_body), do: :ok

  defp sentence_length(%{sentence_word_counts: []}), do: :n_a

  defp sentence_length(%{sentence_word_counts: counts}) do
    long = Enum.count(counts, &(&1 > @long_sentence_words))
    ratio = long / length(counts)

    if ratio > @long_sentence_ratio do
      finding(:info, :long_sentences, :body, %{
        percent: round(ratio * 100),
        max: @long_sentence_words
      })
    else
      :ok
    end
  end

  defp paragraph_length(%{paragraph_word_counts: []}), do: :n_a

  defp paragraph_length(%{paragraph_word_counts: counts}) do
    case Enum.count(counts, &(&1 > @long_paragraph_words)) do
      0 -> :ok
      long -> finding(:info, :long_paragraphs, :body, %{count: long, max: @long_paragraph_words})
    end
  end

  defp flesch(_body, false), do: :n_a
  defp flesch(%{sentence_count: 0}, _english?), do: :n_a
  defp flesch(%{word_count: count}, _english?) when count < @flesch_floor_words, do: :n_a

  defp flesch(body, _english?) do
    score =
      206.835 - 1.015 * (body.word_count / body.sentence_count) -
        84.6 * (body.syllable_count / body.word_count)

    rounded = score |> max(0.0) |> min(100.0) |> Float.round(1)

    if rounded < @hard_to_read_below,
      do: finding(:info, :hard_to_read, :body, %{score: rounded}),
      else: :ok
  end
end
