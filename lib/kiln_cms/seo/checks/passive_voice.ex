defmodule KilnCMS.Seo.Checks.PassiveVoice do
  @moduledoc """
  How much of the document is written in the passive voice (#551).

  ## Read this before trusting the number

  #476 hedged this as "passive-ish heuristics **where feasible**" and #551
  deferred it on the grounds that a regex-grade detector has a high
  false-positive rate. Both are right, and shipping it does not make them
  wrong — so the design is built around the limitation rather than around
  pretending it is not there:

    * **Always `:info`, never a warning.** Passive voice is not categorically
      bad writing. "The vaccine was approved in March" has no useful active
      form, and scientific and legal registers use it deliberately. This
      reports a proportion; it does not tell anyone they are wrong.
    * **A threshold, not a per-sentence flag.** Highlighting individual
      sentences would put a false positive in front of an editor as a specific
      accusation. A whole-document percentage over a generous floor is a much
      weaker claim, and a weaker claim is the honest one to make from this
      evidence.
    * **English only**, gated the same way readability is.

  ## What it actually detects

  A form of *to be* followed within a couple of words by something that looks
  like a past participle. English past participles cannot be identified
  reliably without a part-of-speech tagger, and there is not one in the tree,
  so "looks like" is:

    * a member of the irregular list below (the common ones — regular `-ed`
      forms cover the rest), or
    * a word ending in `-ed` that is not on the adjective stop-list.

  The known and accepted misses and false hits:

    * "was tired", "is interested", "were excited" — predicate adjectives that
      end in `-ed`. The stop-list catches the frequent ones and nothing else.
    * "was going", "is running" — progressive, not passive. Excluded by
      requiring a participle rather than any verb.
    * "has been eaten" — caught, because `been` is in the be-list.
    * "got promoted" — missed; the *get*-passive is not detected at all.

  A tagger would fix most of this. Until there is one, the honest position is a
  soft signal with its error bars written down, which is what this is.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  @impl Kiln.Advisory
  def lenses, do: [:seo]

  # Yoast's own guideline. Generous on purpose — below this, the estimate's
  # error bars are wider than the finding would be useful.
  @max_percentage 15

  # Under this many sentences a percentage is noise: one passive sentence in
  # four is 25%, which says nothing about the document.
  @floor_sentences 8

  @be_forms ~w(is are was were be been being am)

  # Common irregular past participles. Regular `-ed` forms are caught by shape,
  # so this only needs the ones that do not end in `-ed`.
  @irregular ~w(
    been born broken brought built bought caught chosen come cut done drawn
    driven eaten fallen felt fought found given gone grown heard held hidden
    kept known laid led left lent lost made meant met paid put read run said
    seen sent set shown shut sold sent spent stood taken taught told thought
    understood worn won written
  )

  # `-ed` words that are almost always predicate adjectives after *to be*.
  # Every entry here is a false positive somebody would otherwise have to
  # explain away, and the list is deliberately short: guessing beyond the
  # obvious ones would start hiding real passives.
  @adjectives ~w(
    tired interested excited bored worried pleased satisfied surprised
    concerned involved located based limited related known advanced
    complicated detailed dedicated experienced qualified retired married
    aged closed opened crowded gifted talented
  )

  @impl Kiln.Advisory
  def check(%Context{body: body} = context) do
    cond do
      not Context.english?(context) -> :n_a
      body.sentence_count < @floor_sentences -> :n_a
      true -> report(body)
    end
  end

  defp report(body) do
    passive = count_passive(body.text)
    percentage = round(passive * 100 / body.sentence_count)

    if percentage > @max_percentage,
      do:
        finding(:info, :passive_voice_high, :body, %{
          percentage: percentage,
          max: @max_percentage
        }),
      else: :ok
  end

  @doc """
  How many sentences in `text` look passive.

  Public so the heuristic can be tested on its own — including the cases it is
  documented to get wrong, which is the only way those stay documented rather
  than becoming surprises.
  """
  @spec count_passive(String.t()) :: non_neg_integer()
  def count_passive(text) when is_binary(text) do
    text
    |> String.split(~r/[.!?]+/u, trim: true)
    |> Enum.count(&passive_sentence?/1)
  end

  defp passive_sentence?(sentence) do
    words =
      sentence
      |> String.downcase()
      |> String.split(~r/[^a-z']+/u, trim: true)

    words
    |> Enum.with_index()
    |> Enum.any?(fn {word, index} ->
      word in @be_forms and participle_within?(words, index + 1)
    end)
  end

  # Two words of slack after the auxiliary, so "was quickly approved" and "was
  # not approved" are caught while "was the report" is not. Three would start
  # spanning clause boundaries: "was clear that he arrived" is not passive.
  defp participle_within?(words, from) do
    words
    |> Enum.slice(from, 2)
    |> Enum.any?(&participle?/1)
  end

  defp participle?(word) do
    cond do
      word in @adjectives -> false
      word in @irregular -> true
      String.ends_with?(word, "ed") and String.length(word) > 3 -> true
      true -> false
    end
  end
end
