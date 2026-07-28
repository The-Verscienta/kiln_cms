defmodule KilnCMS.Seo.BodyStats do
  @moduledoc """
  The expensive half of SEO analysis (#476): everything that requires walking
  the block tree.

  `KilnCMS.Seo.Analyzer` is cheap — it compares a handful of short strings — but
  the facts it compares *against* (word count, headings, first paragraph, images
  missing alt text) mean touching every block. Splitting them lets the editor
  recompute the analysis on every keystroke while recomputing these stats only
  when the body actually changes.

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

  @type t :: %__MODULE__{
          text: String.t(),
          folded_text: String.t(),
          word_count: non_neg_integer(),
          syllable_count: non_neg_integer(),
          first_paragraph: String.t(),
          headings: [heading()],
          sentence_count: non_neg_integer(),
          sentence_word_counts: [non_neg_integer()],
          paragraph_word_counts: [non_neg_integer()],
          image_count: non_neg_integer(),
          images_missing_alt: [non_neg_integer()],
          internal_link_paths: [String.t()]
        }

  defstruct text: "",
            folded_text: "",
            word_count: 0,
            syllable_count: 0,
            first_paragraph: "",
            headings: [],
            sentence_count: 0,
            sentence_word_counts: [],
            paragraph_word_counts: [],
            image_count: 0,
            images_missing_alt: [],
            internal_link_paths: []

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
    words = String.split(text, ~r/\s+/u, trim: true)
    sentences = sentences(text)
    folded = fold(text)

    %__MODULE__{
      text: text,
      folded_text: folded,
      word_count: length(words),
      syllable_count: syllable_count(folded),
      first_paragraph: List.first(paragraphs) || "",
      headings: Enum.reverse(walked.headings),
      sentence_count: length(sentences),
      sentence_word_counts: Enum.map(sentences, &count_words/1),
      paragraph_word_counts: Enum.map(paragraphs, &count_words/1),
      image_count: walked.image_count,
      images_missing_alt: Enum.reverse(walked.images_missing_alt),
      internal_link_paths: walked.links |> Enum.reverse() |> Enum.uniq()
    }
  end

  @doc """
  Case- and whitespace-folded text, for substring matching (keyphrase density).

  Deliberately *not* `Slug.derive/1`: routing the whole body through slug
  normalization cost ~80ms on a long document because of NFD normalization and
  per-word stop-word filtering, and this sits in the editor's keystroke path.
  Folding is a plain downcase plus whitespace collapse, which is all a
  substring count needs.
  """
  @spec fold(String.t()) :: String.t()
  def fold(text),
    do: text |> to_string() |> String.downcase() |> String.replace(~r/\s+/u, " ")

  @doc """
  Approximate English syllable count for the whole text, for Flesch scoring.

  Vowel groups minus silent trailing "e"s — the standard cheap approximation,
  but counted in **two whole-text scans** rather than per word. Running the
  per-word version over a long document cost ~140ms, and this sits in the
  editor's keystroke path.

  The trade-off is that vowel-less tokens ("1997", "—") contribute 0 rather
  than the 1 a per-word count would give them. Flesch is a heuristic reported
  to one decimal place; the difference is not observable in the advice.
  """
  @spec syllable_count(String.t()) :: non_neg_integer()
  def syllable_count(folded_text) do
    groups = length(Regex.scan(~r/[aeiouy]+/u, folded_text))
    silent_e = length(Regex.scan(~r/[^aeiouy\s][e](?![a-z])/u, folded_text))

    max(groups - silent_e, 0)
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
    do: %{headings: [], paragraphs: [], links: [], image_count: 0, images_missing_alt: []}

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

  defp collect(%KilnCMS.Blocks.Heading{} = block, _index, acc) do
    add_heading(acc, clamp_level(block.level), to_string(block.text || ""))
  end

  defp collect(%KilnCMS.Blocks.Image{} = block, index, acc) do
    acc = %{acc | image_count: acc.image_count + 1}

    if blank?(block.alt),
      do: %{acc | images_missing_alt: [index | acc.images_missing_alt]},
      else: acc
  end

  defp collect(%KilnCMS.Blocks.RichText{} = block, _index, acc) do
    block.body |> List.wrap() |> Enum.reduce(acc, &collect_pt/2)
  end

  defp collect(_block, _index, acc), do: acc

  # A Portable Text node: headings by `style`, paragraphs otherwise, plus any
  # link annotations hanging off `markDefs`.
  defp collect_pt(%{} = node, acc) do
    acc = node |> mark_def_hrefs() |> Enum.reduce(acc, &add_link(&2, &1))
    text = pt_text(node)

    case heading_level(node["style"]) do
      nil -> add_paragraph(acc, text)
      level -> add_heading(acc, level, text)
    end
  end

  defp collect_pt(_node, acc), do: acc

  defp heading_level("h" <> digit) do
    case Integer.parse(digit) do
      {level, ""} when level in 1..6 -> level
      _ -> nil
    end
  end

  defp heading_level(_style), do: nil

  # Tables keep their spans (and markDefs) one level deeper, inside cells.
  defp mark_def_hrefs(%{"_type" => "table"} = node) do
    node
    |> Map.get("rows", [])
    |> List.wrap()
    |> Enum.flat_map(&(&1 |> maybe_get("cells") |> List.wrap()))
    |> Enum.flat_map(&hrefs/1)
  end

  defp mark_def_hrefs(node), do: hrefs(node)

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

  defp add_heading(acc, level, text) do
    if blank?(text),
      do: acc,
      else: %{acc | headings: [%{level: level, text: String.trim(text)} | acc.headings]}
  end

  defp add_paragraph(acc, text) do
    if blank?(text),
      do: acc,
      else: %{acc | paragraphs: [String.trim(text) | acc.paragraphs]}
  end

  # Only same-origin paths are internal links; absolute URLs point elsewhere and
  # anchors/mailto aren't navigation.
  defp add_link(acc, "/" <> _ = href), do: %{acc | links: [href | acc.links]}
  defp add_link(acc, _href), do: acc

  defp clamp_level(level) when level in 1..6, do: level
  defp clamp_level(_level), do: 2

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
