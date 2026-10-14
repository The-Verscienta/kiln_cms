defmodule Kiln.Advisory.Body do
  @moduledoc """
  The facts an advisory check judges a body by: word count, headings, first
  paragraph, images missing alt text, links. A check reads them from
  `context.body` (`Kiln.Advisory.Context`).

  Advisory checks are cheap — they compare a handful of short strings — but
  these facts mean touching every block. Keeping them apart from the checks
  lets the editor re-run every check on each keystroke while recomputing the
  facts only when the body actually changes.

  Deliberately feature-neutral: nothing here is SEO-specific, and the heading
  and image facts are exactly what an accessibility checker (#495) needs. One
  walk feeds every registered check.

  The core fills this struct by walking the block tree (`Kiln.Advisory.Walk`,
  which needs the core's block types). This module holds the struct and the
  pure text helpers a check may want to reuse, which is what lets a check
  ship in a plugin that depends only on `kiln_plugin` (#1909).
  """

  @typedoc """
  One heading, with the top-level block it lives in.

  `index` is what lets the editor jump to a heading a check names — a skipped
  level is reported *at* the heading that skipped, not just as a pair of
  numbers — and, like a link's, it is the index of the top-level ancestor.
  """
  @type heading :: %{level: pos_integer(), text: String.t(), index: non_neg_integer()}

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

  # The walk lived here until this module moved into `kiln_plugin` (#1909).
  # These keep a 1.x overlay that called it working; they reach the core at
  # runtime, so outside a KilnCMS build they raise `UndefinedFunctionError`.
  @walk Kiln.Advisory.Walk
  @compile {:no_warn_undefined, @walk}
  @dialyzer {:no_unknown, compute: 1, from_typed: 1, from_indexed: 1}

  @doc false
  @deprecated "Use Kiln.Advisory.Walk.compute/1"
  def compute(blocks), do: @walk.compute(blocks)

  @doc false
  @deprecated "Use Kiln.Advisory.Walk.from_typed/1"
  def from_typed(typed), do: @walk.from_typed(typed)

  @doc false
  @deprecated "Use Kiln.Advisory.Walk.from_indexed/1"
  def from_indexed(indexed), do: @walk.from_indexed(indexed)

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
end
