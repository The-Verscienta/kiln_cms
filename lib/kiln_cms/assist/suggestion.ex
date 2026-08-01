defmodule KilnCMS.Assist.Suggestion do
  @moduledoc """
  What a `KilnCMS.Assist.Generator` produced — and the boundary where model
  output stops being trusted.

  `normalize/2` runs over every suggestion regardless of which generator made
  it. Where `KilnCMS.Seo.Draft.normalize/1` clamps a handful of short strings
  bound for `<meta>` tags, this clamps prose bound for the **page body**, so
  the threat is different and so is the answer.

  ## Plain text, never markup

  The suggestion is carried to the browser as a list of paragraph *strings* and
  inserted through a TipTap command as plain text nodes. It is never HTML on
  the wire and never `Phoenix.HTML.raw/1` anywhere. That is the load-bearing
  control: a model talked into emitting `<script>` produces a paragraph that
  visibly reads `<script>`, which an author will not click Insert on.

  Everything below is defence in depth behind that:

    * tags are stripped, so nothing arrives *looking* like markup;
    * markdown links collapse to their label — the anchor is the payload in a
      spam-link injection, and the label alone can't be one;
    * control and format characters go, including NUL (Postgres raises rather
      than erroring on `0x00` in a text column, which would kill the LiveView
      and the author's unsaved work) and the bidi overrides that render a
      snippet reversed, Trojan-Source style;
    * length is clamped, so a runaway generation can't paste a megabyte into
      the editor.

  Bare URLs are deliberately **left visible as text** rather than dropped. In a
  `<meta>` tag a URL is pure payload and `KilnCMS.Seo.Draft` is right to refuse
  it; in body prose "see example.com/spec" is ordinary writing, it creates no
  link (the editor's TipTap build carries no autolink extension, and the block
  cast re-sanitizes on save), and the author reads the paragraph before
  accepting it.

  Nothing here is ever written to a record on its own.
  """

  alias KilnCMS.Assist
  alias KilnCMS.Assist.Action

  @type t :: %__MODULE__{
          action: Action.id() | nil,
          paragraphs: [String.t()],
          word_count: non_neg_integer(),
          model: String.t() | nil,
          usage: map() | nil,
          truncated?: boolean()
        }

  defstruct action: nil, paragraphs: [], word_count: 0, model: nil, usage: nil, truncated?: false

  @doc """
  Clean raw generator text into a suggestion.

  `{:error, :empty}` when nothing usable survives — the caller reports that as
  a failed generation rather than offering the author a blank card.
  """
  @spec normalize(String.t(), Action.id() | nil) :: {:ok, t()} | {:error, :empty}
  def normalize(text, action \\ nil)

  def normalize(text, action) when is_binary(text) do
    {cleaned, truncated?} = text |> clean() |> clamp(Assist.max_output_chars())

    case paragraphs(cleaned) do
      [] ->
        {:error, :empty}

      paragraphs ->
        {:ok,
         %__MODULE__{
           action: action,
           paragraphs: paragraphs,
           # Counted once, here. The editor's card shows it, and that card sits
           # inside the block comprehension — recomputing it per render meant a
           # Unicode split over the whole suggestion on every keystroke,
           # cursor event and autosave for as long as the card stayed open.
           word_count: Kiln.Advisory.Body.count_words(Enum.join(paragraphs, " ")),
           truncated?: truncated?
         }}
    end
  end

  def normalize(_text, _action), do: {:error, :empty}

  @doc "The suggestion as one string, paragraphs separated by a blank line."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{paragraphs: paragraphs}), do: Enum.join(paragraphs, "\n\n")

  # ── Sanitizing ──────────────────────────────────────────────────────────────

  defp clean(text) do
    text
    |> strip_fences()
    |> strip_tags()
    |> decode_entities()
    # Markdown link and image syntax → the label alone.
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/u, "\\1")
    # Residual emphasis and inline-code marks, paired only.
    |> String.replace(~r/(\*\*|__)(.+?)\1/us, "\\2")
    |> String.replace(~r/(?<![\p{L}\p{N}])([*_`])(?!\s)(.+?)(?<!\s)\1/us, "\\2")
    # Leading heading and quote markers the prompt asked the model not to emit.
    # List markers are deliberately NOT stripped here — `paragraphs/1` needs to
    # see them to tell a list from hard-wrapped prose.
    |> String.replace(~r/^[ \t]*(?:[#]{1,6}[ \t]+|>[ \t]?)/mu, "")
    # Normalize newlines before the control-character sweep below, which would
    # otherwise eat them, and turn tabs into spaces before it too — a stripped
    # tab would join the words either side of it.
    |> String.replace(~r/\r\n?/u, "\n")
    |> String.replace("\t", " ")
    |> strip_control()
    |> String.replace(~r/[^\S\n]+/u, " ")
    # Trailing indentation would otherwise leave " " between two newlines, and
    # the blank-line split below would stop seeing a paragraph break at all.
    |> String.replace(~r/ *\n */u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  # A model asked for prose still fences it sometimes. Drop the fence lines
  # rather than the block: the prose inside them is the answer.
  defp strip_fences(text) do
    String.replace(text, ~r/^[ \t]*(?:```|~~~)[^\n]*$/mu, "")
  end

  # Only things that are actually tags — a name or a closing slash after the
  # `<`, or a comment. A blanket `<[^>]*>` also eats ordinary prose: "use x < y
  # and a > b" came out as "use x b", silently deleting a clause from a
  # suggestion whose selling point is that it keeps every fact.
  #
  # Replaced with a space, not removed: "one<br>two" must not become "onetwo".
  defp strip_tags(text) do
    String.replace(text, ~r|<!--.*?-->|us, " ")
    |> String.replace(~r|</?[A-Za-z][^>]*>|u, " ")
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  # Decoded, not blanked. Models routinely escape `&` and apostrophes, and
  # substituting a space split the word around them — "AT&amp;T and R&amp;D"
  # became "AT T and R D". Decoding runs *after* `strip_tags/1` on purpose:
  # `&lt;script&gt;` then survives as the literal text "<script>", which is
  # exactly what this module wants an author to see and refuse.
  defp decode_entities(text) do
    String.replace(text, ~r/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);/u, fn entity ->
      entity |> String.slice(1..-2//1) |> entity_char() || entity
    end)
  end

  defp entity_char("#x" <> hex), do: codepoint(hex, 16)
  defp entity_char("#X" <> hex), do: codepoint(hex, 16)
  defp entity_char("#" <> digits), do: codepoint(digits, 10)
  defp entity_char(name), do: Map.get(@entities, String.downcase(name))

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      # Valid scalar values only. A surrogate or an out-of-range number would
      # raise in `List.to_string/1`, and the decoded character still has to
      # survive `strip_control/1` below, so nothing dangerous is smuggled in
      # by writing it as an entity.
      {number, ""} when number in 0x20..0xD7FF or number in 0xE000..0x10FFFF ->
        <<number::utf8>>

      _ ->
        nil
    end
  end

  # Control (Cc) and format (Cf) characters. NUL is here: Postgres rejects 0x00
  # in a text column by *raising*, killing the LiveView and the author's
  # unsaved work rather than returning a changeset error. U+202E and friends
  # are here too — they render the snippet reversed, Trojan-Source style.
  #
  # ZWNJ and ZWJ are exempt. They are Cf, but they are also ordinary
  # orthography in Persian, Arabic and the Indic scripts, and structural in
  # emoji sequences — stripping them turned "می‌روم" into a different word and
  # broke family emoji into three people. This feature pins output to the
  # *record's* locale, so the scripts it would corrupt are precisely the ones
  # it exists to serve.
  #
  # Runs before the whitespace collapse so a removed character can't leave a
  # double space behind.
  defp strip_control(text) do
    String.replace(text, ~r/(?![\n\x{200C}\x{200D}])[\p{Cc}\p{Cf}]/u, "")
  end

  defp clamp(text, max) do
    if String.length(text) <= max,
      do: {text, false},
      else: {String.slice(text, 0, max), true}
  end

  defp paragraphs(text) do
    text
    |> String.split(~r/\n{2,}/u)
    |> Enum.flat_map(&split_block/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Two or more marker lines in one blank-line-delimited block is a list.
  @list_line ~r/^(?:[-*+]|\d+[.)])[ \t]+\S/u

  # Within a block, hard-wrapped prose joins back into one paragraph — but a
  # list must not. The output is inserted as plain paragraphs, which cannot
  # carry a bullet, so joining "- First\n- Second" produced the single
  # nonsensical sentence "First Second". `KilnCMS.Assist.Prompt` asks for prose
  # and expects to be ignored: models reach for a bulleted list regardless.
  defp split_block(block) do
    lines = block |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if Enum.count(lines, &Regex.match?(@list_line, &1)) >= 2 do
      Enum.map(lines, &strip_list_marker/1)
    else
      # A bullet on a lone line is still a bullet; a lone "1990. The company…"
      # is a year, so ordered markers are only stripped inside a real list.
      [lines |> Enum.map_join(" ", &String.replace(&1, ~r/^[-*+][ \t]+/u, "")) |> String.trim()]
    end
  end

  defp strip_list_marker(line),
    do: String.replace(line, ~r/^(?:[-*+]|\d+[.)])[ \t]+/u, "")
end
