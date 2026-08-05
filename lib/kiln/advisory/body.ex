defmodule Kiln.Advisory.Body do
  @moduledoc """
  The expensive half of content analysis: everything that requires walking the
  block tree.

  Advisory checks are cheap — they compare a handful of short strings — but the
  facts they compare *against* (word count, headings, first paragraph, images
  missing alt text) mean touching every block. Splitting them lets the editor
  recompute the checks on every keystroke while recomputing these facts only
  when the body actually changes.

  Deliberately feature-neutral, and part of `Kiln.Advisory` rather than the SEO
  namespace: nothing here is SEO-specific, and the heading and image facts are
  exactly what an accessibility checker (#495) needs. One walk feeds every
  registered check.

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

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.CMS.BlockText
  alias KilnCMS.CMS.TypedBlocks

  @type heading :: %{level: pos_integer(), text: String.t()}

  @typedoc """
  One link, with the text a reader actually sees.

  `href` alone was enough while the only question was "does this resolve"
  (#474). #495 asks a different one — "does this text say where it goes" —
  which needs the anchor text, and the top-level block index so the editor can
  offer a jump link.
  """
  @type link :: %{text: String.t(), href: String.t(), index: non_neg_integer()}

  @type t :: %__MODULE__{
          text: String.t(),
          folded_text: String.t(),
          folded_words: [String.t()],
          word_count: non_neg_integer(),
          syllable_count: non_neg_integer(),
          first_paragraph: String.t(),
          headings: [heading()],
          sentence_count: non_neg_integer(),
          sentence_word_counts: [non_neg_integer()],
          paragraph_word_counts: [non_neg_integer()],
          image_count: non_neg_integer(),
          images_missing_alt: [non_neg_integer()],
          internal_link_paths: [String.t()],
          links: [link()],
          empty_headings: [non_neg_integer()],
          capitalised_runs: [String.t()]
        }

  defstruct text: "",
            folded_text: "",
            folded_words: [],
            word_count: 0,
            syllable_count: 0,
            first_paragraph: "",
            headings: [],
            sentence_count: 0,
            sentence_word_counts: [],
            paragraph_word_counts: [],
            image_count: 0,
            images_missing_alt: [],
            internal_link_paths: [],
            links: [],
            empty_headings: [],
            capitalised_runs: []

  @doc """
  Derive the body facts the analyzer needs. Safe on `nil` and on an empty list.
  """
  @spec compute(term()) :: t()
  def compute(blocks), do: blocks |> List.wrap() |> TypedBlocks.to_typed() |> from_typed()

  @doc """
  Like `compute/1`, but for callers that already hold typed blocks.

  Worth the extra function: `TypedBlocks.to_typed/1` costs ~34ms on a
  500-block document, and the content editor has already paid it to render the
  preview. Re-typing an already-typed list would double that on every
  keystroke.
  """
  @spec from_typed([struct()]) :: t()
  def from_typed(typed) when is_list(typed) do
    text = BlockText.to_text(typed)
    walked = Enum.reduce(Enum.with_index(typed), empty_walk(), &walk_top_level/2)

    # Every accumulator is built by prepending, so each is reversed exactly once
    # here to restore document order.
    paragraphs = Enum.reverse(walked.paragraphs)
    links = Enum.reverse(walked.links)
    words = String.split(text, ~r/\s+/u, trim: true)
    sentences = sentences(text)
    folded = fold(text)

    %__MODULE__{
      text: text,
      folded_text: folded,
      folded_words: tokenize(folded),
      word_count: length(words),
      syllable_count: syllable_count(folded),
      first_paragraph: List.first(paragraphs) || "",
      headings: Enum.reverse(walked.headings),
      sentence_count: length(sentences),
      sentence_word_counts: Enum.map(sentences, &count_words/1),
      paragraph_word_counts: Enum.map(paragraphs, &count_words/1),
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

  @doc """
  Case- and whitespace-folded text, for substring matching (keyphrase density).

  Deliberately *not* `KilnCMS.Slug.derive/1`: routing the whole body through slug
  normalization cost ~80ms on a long document because of NFD normalization and
  per-word stop-word filtering, and this sits in the editor's keystroke path.
  Folding is a plain downcase plus whitespace collapse, which is all a
  substring count needs.
  """
  @spec fold(String.t()) :: String.t()
  def fold(text),
    do: text |> to_string() |> String.downcase() |> String.replace(~r/\s+/u, " ")

  @doc """
  Folded text as clean word tokens — punctuation dropped, so `firing.` and
  `firing` compare equal.

  Keyphrase density matches against these rather than doing a substring scan of
  `folded_text`: a substring scan reports keyphrase `art` as present in `part`,
  `start`, `heart` and `chart`, which produced spurious "keyword stuffing"
  warnings for a keyphrase used correctly.
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(folded_text),
    do: String.split(folded_text, ~r/[^\p{L}\p{N}]+/u, trim: true)

  @doc """
  Approximate English syllable count for the whole text, for Flesch scoring.

  Vowel groups minus a silent trailing "e", floored at **one syllable per
  word** — the standard cheap approximation.

  That per-word floor is load-bearing and was lost in an earlier version that
  counted with two whole-text regex scans: any word whose only vowel is a
  silent final `e` (`the`, `he`, `she`, `be`, `we`, `me`) netted out to zero,
  inflating Flesch by ~17 points and silencing the readability warning on
  exactly the prose it exists to flag. Keep the counting per word.

  Still cheap: one regex to tokenize, then a plain charlist reduce per word
  rather than two regex executions each.
  """
  @spec syllable_count(String.t()) :: non_neg_integer()
  def syllable_count(folded_text) do
    folded_text
    |> String.split(~r/[^a-z]+/u, trim: true)
    |> Enum.reduce(0, &(&2 + word_syllables(&1)))
  end

  defp word_syllables(word) do
    groups = vowel_groups(word)
    silent_e = if groups > 1 and String.ends_with?(word, "e"), do: 1, else: 0

    max(groups - silent_e, 1)
  end

  defp vowel_groups(word) do
    word
    |> String.to_charlist()
    |> Enum.reduce({0, false}, fn char, {count, in_group?} ->
      case {char in ~c"aeiouy", in_group?} do
        {true, false} -> {count + 1, true}
        {true, true} -> {count, true}
        {false, _} -> {count, false}
      end
    end)
    |> elem(0)
  end

  @doc "Split text into sentences. Language-neutral: terminators plus whitespace."
  @spec sentences(String.t()) :: [String.t()]
  def sentences(text) do
    text
    |> String.split(~r/(?<=[.!?。！？])\s+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Whitespace-delimited word count."
  @spec count_words(String.t()) :: non_neg_integer()
  def count_words(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()

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
    acc = node |> node_links(index) |> Enum.reduce(acc, &add_link(&2, &1))
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

  @doc """
  Every link href on one Portable Text node, including the ones inside a table's
  cells.

  Public because the external link checker (`KilnCMS.Links.Extract`) walks the
  same annotations from a background job, and two copies of "where a link hides
  in Portable Text" would drift the first time a new nested node type lands —
  tables already made that mistake available once.

  Returns hrefs of every kind: same-origin paths, absolute URLs, `mailto:`.
  Deciding which are interesting is the caller's job.
  """
  @spec node_hrefs(term()) :: [String.t()]
  def node_hrefs(node)

  # Tables keep their spans (and markDefs) one level deeper, inside cells.
  def node_hrefs(%{"_type" => "table"} = node) do
    node
    |> Map.get("rows", [])
    |> List.wrap()
    |> Enum.flat_map(&(&1 |> maybe_get("cells") |> List.wrap()))
    |> Enum.flat_map(&hrefs/1)
  end

  def node_hrefs(node), do: hrefs(node)

  @doc """
  Every link on one Portable Text node, paired with the text a reader sees.

  `node_hrefs/1` answers "where does this go", which is all the link *checker*
  needs. This answers "what does it say", which is what an accessibility check
  needs — and the two cannot be derived from each other, because the text
  lives on the child spans while the href lives on the `markDefs` entry they
  reference by `_key`.

  A link annotation with no matching span (an orphaned markDef, which real
  editors do produce) yields `""` rather than being dropped: an empty link is
  exactly the defect worth reporting, so losing it here would hide it.
  """
  @spec node_links(term(), non_neg_integer()) :: [link()]
  def node_links(node, index)

  # Tables keep their spans and markDefs one level deeper, inside cells — the
  # same shape `node_hrefs/1` has to handle, for the same reason.
  def node_links(%{"_type" => "table"} = node, index) do
    node
    |> Map.get("rows", [])
    |> List.wrap()
    |> Enum.flat_map(&(&1 |> maybe_get("cells") |> List.wrap()))
    |> Enum.flat_map(&links(&1, index))
  end

  def node_links(node, index), do: links(node, index)

  defp links(%{} = node, index) do
    children = node |> Map.get("children", []) |> List.wrap()

    node
    |> Map.get("markDefs", [])
    |> List.wrap()
    |> Enum.filter(&match?(%{"_type" => "link"}, &1))
    |> Enum.map(fn def ->
      %{
        text: anchor_text(children, def["_key"]),
        href: to_string(def["href"] || ""),
        index: index
      }
    end)
  end

  defp links(_node, _index), do: []

  # The spans carrying this annotation, in document order. `marks` holds a mix
  # of style names ("strong") and markDef keys, so matching is by key.
  defp anchor_text(children, key) when is_binary(key) do
    children
    |> Enum.filter(fn child ->
      is_map(child) and key in (child |> Map.get("marks", []) |> List.wrap())
    end)
    |> Enum.map_join(&to_string(Map.get(&1, "text", "")))
    |> String.trim()
  end

  defp anchor_text(_children, _key), do: ""

  defp hrefs(%{} = node) do
    node
    |> Map.get("markDefs", [])
    |> List.wrap()
    |> Enum.filter(&match?(%{"_type" => "link"}, &1))
    |> Enum.map(&to_string(&1["href"] || ""))
  end

  defp hrefs(_node), do: []

  defp maybe_get(map, key) when is_map(map), do: Map.get(map, key)
  defp maybe_get(_map, _key), do: nil

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
  # branch stays because `Body.compute/1` is documented as total over
  # whatever is stored, including rows a migration or a direct write left
  # behind.
  defp add_heading(acc, level, text, index) do
    if blank?(text),
      do: %{acc | empty_headings: [index | acc.empty_headings]},
      else: %{acc | headings: [%{level: level, text: String.trim(text)} | acc.headings]}
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
