defmodule Kiln.Advisory.Walk do
  @moduledoc """
  Fills a `Kiln.Advisory.Body` by walking the block tree — the expensive half
  of content analysis.

  `Kiln.Advisory.Body` (the struct and its text helpers) ships in the
  `kiln_plugin` package so a plugin's advisory check can match on it; the walk
  stays in the core because it pattern-matches the core's block types (#1909).

  `compute/1` accepts whatever the caller has: the stored `{:array, BlockUnion}`
  value, typed block structs, or the raw string-keyed maps the content editor
  holds for an unsaved draft. Everything routes through
  `KilnCMS.CMS.TypedBlocks.to_typed/1`, which is total, so this never raises on
  malformed input — an unparseable block simply contributes nothing.

  Nested `columns` children are walked too, via
  `KilnCMS.Blocks.Columns.child_blocks_flat/1`. Findings from a nested block are
  attributed to the index of its **top-level** ancestor, because that is the
  block the editor can actually scroll to.
  """

  alias Kiln.Advisory.Body
  alias KilnCMS.Blocks.Columns
  alias KilnCMS.CMS.BlockText
  alias KilnCMS.CMS.TypedBlocks

  @doc """
  Derive the body facts the analyzer needs. Safe on `nil` and on an empty list.
  """
  @spec compute(term()) :: Body.t()
  def compute(blocks), do: blocks |> List.wrap() |> TypedBlocks.to_typed() |> from_typed()

  @doc """
  Like `compute/1`, but for callers that already hold typed blocks.

  Worth the extra function: `TypedBlocks.to_typed/1` costs ~34ms on a
  500-block document, and the content editor has already paid it to render the
  preview. Re-typing an already-typed list would double that on every
  keystroke.
  """
  @spec from_typed([struct()]) :: Body.t()
  def from_typed(typed) when is_list(typed), do: typed |> Enum.with_index() |> from_indexed()

  @doc """
  Like `from_typed/1`, but every block carries the index its findings report
  against, as `{block, index}`.

  For a list that is no longer one-to-one with the editor's cards: after
  `KilnCMS.CMS.Fragments.expand_indexed/3` inlines a fragment, the blocks it
  produced share the fragment's index and the blocks after it keep their own.
  Positions in the expanded list would name the wrong card.
  """
  @spec from_indexed([{struct(), non_neg_integer()}]) :: Body.t()
  def from_indexed(indexed) when is_list(indexed) do
    text = indexed |> Enum.map(&elem(&1, 0)) |> BlockText.to_text()
    walked = Enum.reduce(indexed, empty_walk(), &walk_top_level/2)

    # Every accumulator is built by prepending, so each is reversed exactly once
    # here to restore document order.
    paragraphs = Enum.reverse(walked.paragraphs)
    links = Enum.reverse(walked.links)
    words = String.split(text, ~r/\s+/u, trim: true)
    sentences = Body.sentences(text)
    folded = Body.fold(text)

    %Body{
      text: text,
      folded_text: folded,
      folded_words: Body.tokenize(folded),
      word_count: length(words),
      syllable_count: Body.syllable_count(folded),
      first_paragraph: List.first(paragraphs) || "",
      headings: Enum.reverse(walked.headings),
      sentence_count: length(sentences),
      sentence_word_counts: Enum.map(sentences, &Body.count_words/1),
      paragraph_word_counts: Enum.map(paragraphs, &Body.count_words/1),
      image_count: walked.image_count,
      images_missing_alt: Enum.reverse(walked.images_missing_alt),
      links: links,
      # Per block, never over the joined `text`: `BlockText.to_text/1` joins
      # blocks with a single SPACE, and a heading carries no terminal
      # punctuation — so two short shouted headings ("SHIPPING INFO",
      # "RETURNS POLICY") become one four-word "sentence" and a false
      # positive. Sentence splitting inside a block can't see a boundary that
      # isn't in the string.
      capitalised_runs: capitalised_runs(paragraphs ++ Enum.map(walked.headings, & &1.text)),
      # Derived from the same walk rather than accumulated separately, so the
      # two can't disagree about what counts as a link. Only same-origin paths
      # are internal; absolute URLs point elsewhere and anchors/mailto aren't
      # navigation.
      internal_link_paths:
        links |> Enum.map(& &1.href) |> Enum.filter(&String.starts_with?(&1, "/")) |> Enum.uniq(),
      empty_headings: Enum.reverse(walked.empty_headings)
    }
  end

  # Consecutive capitalised words, per sentence (#495).
  #
  # Computed HERE rather than in `Kiln.Advisory.Checks.AllCaps` because this
  # module is the one that gets memoized: the editor re-runs every check on
  # each keystroke but only recomputes these facts when the body actually
  # changes. Scanning the full text inside the check instead put ~90ms of
  # string work on a 50k-word document into every validate, including the ones
  # that only touched the title.
  #
  # Three word classes, not two, and the third is the point. A word with no
  # cased letters ("2024", "—") or too few ("A", "I") is NEUTRAL: it neither
  # starts a run nor breaks one, and doesn't count toward the length.
  # Treating those as lowercase — the obvious two-way split — breaks
  # "THIS IS A REALLY IMPORTANT NOTICE" into two runs of two at the word "A",
  # so the one sentence the check exists for scores below the threshold and
  # passes silently.
  # Six, not four. Four is the length of a perfectly ordinary list of
  # acronyms — "PDF CSV XML JSON", "HTTP HTTPS TLS SSL", "NASA JPL ESA NOAA" —
  # and a check that flags those on a technical page is one an author turns
  # off, at which point it stops catching the shouted paragraph too. Six is
  # long enough that a run is prose rather than a list.
  @min_run_words 6
  @min_word_length 2

  @spec capitalised_runs([String.t()]) :: [String.t()]
  defp capitalised_runs(texts) do
    Enum.flat_map(texts, fn text ->
      text
      |> String.split(~r/[\r\n]+|(?<=[.!?])\s+/u, trim: true)
      |> Enum.flat_map(&runs_in_sentence/1)
    end)
  end

  # Per sentence, so a capitalised heading followed by a capitalised heading
  # isn't merged into one long false positive.
  defp runs_in_sentence(sentence) do
    sentence
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reduce({[], []}, &extend_run/2)
    |> close_run()
    |> Enum.filter(&(length(&1) >= @min_run_words))
    |> Enum.map(&Enum.join(&1, " "))
  end

  defp extend_run(word, {runs, current}) do
    case classify_case(word) do
      :shouted -> {runs, [word | current]}
      :neutral -> {runs, current}
      :lower -> {close_current(runs, current), []}
    end
  end

  defp close_run({runs, current}), do: runs |> close_current(current) |> Enum.reverse()

  defp close_current(runs, []), do: runs
  defp close_current(runs, current), do: [Enum.reverse(current) | runs]

  # `String.upcase/1` comparison rather than a regex, so this holds for
  # non-Latin scripts too.
  defp classify_case(word) do
    stripped = String.replace(word, ~r/[^\p{L}]/u, "")

    cond do
      String.length(stripped) < @min_word_length -> :neutral
      stripped == String.downcase(stripped) -> :lower
      stripped == String.upcase(stripped) -> :shouted
      true -> :lower
    end
  end

  defp empty_walk,
    do: %{
      headings: [],
      paragraphs: [],
      links: [],
      image_count: 0,
      images_missing_alt: [],
      empty_headings: []
    }

  # Every block in a top-level slot — the block itself plus any `columns`
  # descendants — reports against that slot's index.
  defp walk_top_level({block, index}, acc) do
    block
    |> flatten()
    |> Enum.reduce(acc, &collect(&1, index, &2))
  end

  defp flatten(%Columns{} = block) do
    [block | block |> Columns.child_blocks_flat() |> Enum.flat_map(&flatten/1)]
  end

  defp flatten(block), do: [block]

  defp collect(%KilnCMS.Blocks.Heading{} = block, index, acc) do
    add_heading(acc, clamp_level(block.level), to_string(block.text || ""), index)
  end

  defp collect(%KilnCMS.Blocks.Image{} = block, index, acc) do
    acc = %{acc | image_count: acc.image_count + 1}

    if blank?(block.alt),
      do: %{acc | images_missing_alt: [index | acc.images_missing_alt]},
      else: acc
  end

  defp collect(%KilnCMS.Blocks.RichText{} = block, index, acc) do
    block.body |> List.wrap() |> Enum.reduce(acc, &collect_pt(&1, index, &2))
  end

  defp collect(_block, _index, acc), do: acc

  # A Portable Text node: headings by `style`, paragraphs otherwise, plus any
  # link annotations hanging off `markDefs`.
  defp collect_pt(%{} = node, index, acc) do
    acc = node |> Body.node_links(index) |> Enum.reduce(acc, &add_link(&2, &1))
    text = pt_text(node)

    case heading_level(node["style"]) do
      nil -> add_paragraph(acc, text)
      level -> add_heading(acc, level, text, index)
    end
  end

  defp collect_pt(_node, _index, acc), do: acc

  defp heading_level("h" <> digit) do
    case Integer.parse(digit) do
      {level, ""} when level in 1..6 -> level
      _ -> nil
    end
  end

  defp heading_level(_style), do: nil

  defp pt_text(%{"children" => children}) when is_list(children),
    do: children |> Enum.map_join(&to_string(&1["text"] || "")) |> String.trim()

  defp pt_text(_node), do: ""

  # A blank heading is recorded, not dropped. It used to vanish here, which
  # meant the one heading defect an author cannot see — an empty H2 that
  # renders as a gap and reads to a screen reader as an unlabelled landmark —
  # was the one nothing could report. It stays out of `headings` so the
  # level-order check isn't judging a heading with no text.
  #
  # In practice this fires for Portable Text headings (a TipTap `h2` the
  # author never filled in). A typed `KilnCMS.Blocks.Heading` requires `text`
  # and Ash treats whitespace as blank, so that path can't produce one — the
  # branch stays because `compute/1` is documented as total over
  # whatever is stored, including rows a migration or a direct write left
  # behind.
  defp add_heading(acc, level, text, index) do
    if blank?(text),
      do: %{acc | empty_headings: [index | acc.empty_headings]},
      else: %{
        acc
        | headings: [%{level: level, text: String.trim(text), index: index} | acc.headings]
      }
  end

  defp add_paragraph(acc, text) do
    if blank?(text),
      do: acc,
      else: %{acc | paragraphs: [String.trim(text) | acc.paragraphs]}
  end

  defp add_link(acc, link), do: %{acc | links: [link | acc.links]}

  defp clamp_level(level) when level in 1..6, do: level
  defp clamp_level(_level), do: 2

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
