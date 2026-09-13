defmodule KilnCMS.Markdown do
  @moduledoc """
  Markdown → structured content. The one converter every Markdown entry point
  shares: pasting into the content editor, importing a `.md` file there, the
  `body_markdown` argument on the content write API (JSON:API, GraphQL, MCP),
  and anything else that publishes Markdown into Kiln (a docs publisher, a
  migration script). Call this rather than growing a second one — two
  converters disagree on exactly the edge cases nobody tests.

  ## The route

  Markdown is parsed to an AST (`EarmarkParser`, GFM tables and fenced code
  on), rendered to HTML *here*, and handed to `KilnCMS.Blocks.Html` — the
  adapter the WordPress and portability importers already use — so a Markdown
  heading, list, table or code block becomes exactly the Portable Text an
  imported HTML one does, and a standalone image or video link becomes an
  `image` or `embed` block rather than prose.

  ## Nothing in the source is trusted

  Markdown may carry raw HTML, and its link and image syntax takes any URL.

    * Structure produced by Markdown *syntax* is rendered by this module from
      a closed tag list, with every text run and attribute escaped. A link
      keeps its href only if `KilnCMS.HTMLSanitizer.safe_href/1` accepts it
      (otherwise its text survives without the anchor), and an image keeps
      its src only if `KilnCMS.HTMLSanitizer.safe_image_src/1` does.
    * Raw HTML the author wrote — an HTML block, or inline tags in a line of
      prose — goes through `KilnCMS.HTMLSanitizer.sanitize_rich_text/1`, the
      same allowlist stored rich text is held to. `script`, `style` and
      friends are dropped outright rather than left as visible text.
    * `KilnCMS.Blocks.Html` and the block union's cast then sanitize again on
      the way into storage.

  The retired `earmark` renderer is deliberately not used: it is the package
  with the attribute-escaping advisory, and this module would be sanitizing
  its output anyway.

  ## Front matter

  A leading `---` block of `key: value` lines is removed from the body by
  every function here — it is metadata, never prose. `parse_document/2`
  returns it, and maps `title`, `slug` and `excerpt` (or `description`).
  """

  alias KilnCMS.Blocks.Html
  alias KilnCMS.HTMLSanitizer

  # The largest document any entry point accepts, in bytes. A generous book
  # chapter is ~100 KB; this bounds the parse, not an author.
  @max_bytes 1_000_000

  # Elements Markdown syntax can produce, rendered bare (their attributes are
  # presentation — earmark's table `style="text-align"`, `hr class="thin"` —
  # which Portable Text has nowhere to keep). `a`, `img`, `pre` and `code` are
  # handled separately because they are the ones whose attributes matter.
  @plain_tags ~w(p h1 h2 h3 h4 h5 h6 ul ol li blockquote strong em del table thead tbody tfoot tr th td)
  @void_tags ~w(br hr)

  # Raw HTML blocks that are never content. The sanitizer would strip the tags
  # but keep `alert(1)` as a paragraph of visible text.
  @dropped_raw ~w(script style noscript iframe object embed template head title)

  @typedoc """
  What `parse_document/2` returns. `title`/`slug`/`excerpt` are `nil` when the
  document does not supply them; `front_matter` holds every key it did.
  """
  @type document :: %{
          title: String.t() | nil,
          slug: String.t() | nil,
          excerpt: String.t() | nil,
          front_matter: %{String.t() => String.t()},
          blocks: [Html.block_input()]
        }

  @doc "The largest Markdown source (in bytes) the entry points accept."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  `markdown` as sanitized HTML — safe to render as-is. Front matter is removed.

  Options:

    * `:images` — `:keep` (default) renders `<img>`; `:link` renders each image
      as a link to its URL labelled with its alt text, for a destination that
      holds prose only (see `to_tiptap/2`).
  """
  @spec to_html(String.t() | nil, keyword()) :: String.t()
  def to_html(markdown, opts \\ [])
  def to_html(nil, _opts), do: ""

  def to_html(markdown, opts) when is_binary(markdown) do
    {_front_matter, body} = split_front_matter(markdown)
    body |> parse() |> render(opts)
  end

  @doc """
  `markdown` as typed block inputs (`%{"type" => ..., "value" => ...}`), ready
  for a content write's `block_tree` — prose runs become `rich_text`, a
  standalone image an `image`, a bare YouTube/Vimeo link an `embed`.

  Options: `:media_resolver`, as in `KilnCMS.Blocks.Html.to_blocks/2`.
  """
  @spec to_blocks(String.t() | nil, keyword()) :: [Html.block_input()]
  def to_blocks(markdown, opts \\ [])
  def to_blocks(nil, _opts), do: []

  def to_blocks(markdown, opts) when is_binary(markdown) do
    markdown |> to_html() |> Html.to_blocks(html_opts(opts))
  end

  @doc """
  `markdown` as a TipTap document — prose only, the shape the editor inserts
  when Markdown is pasted into a rich-text block. An image has no node in the
  rich-text schema, so it arrives as a link to the picture (labelled with its
  alt text) rather than vanishing.
  """
  @spec to_tiptap(String.t() | nil) :: map()
  def to_tiptap(nil), do: %{"type" => "doc", "content" => []}

  def to_tiptap(markdown) when is_binary(markdown) do
    markdown |> to_html(images: :link) |> Html.to_tiptap(html_opts([]))
  end

  @doc """
  A whole Markdown document: its metadata and its body blocks.

  The title is the front matter's `title`, else a **leading** `# H1` (the
  first thing in the body — a heading further down is a section, not the
  document's name). A leading H1 that supplied the title, or that repeats the
  front-matter title, is removed from the body: the title is rendered by the
  page, and keeping it would print it twice.

  Options: `:media_resolver`, as in `to_blocks/2`.
  """
  @spec parse_document(String.t() | nil, keyword()) :: document()
  def parse_document(markdown, opts \\ [])

  def parse_document(nil, opts), do: parse_document("", opts)

  def parse_document(markdown, opts) when is_binary(markdown) do
    {front_matter, body} = split_front_matter(markdown)
    nodes = parse(body)
    declared = presence(front_matter["title"])

    {title, nodes} =
      case {leading_h1(nodes), declared} do
        {{heading, rest}, nil} -> {heading, rest}
        {{^declared, rest}, _} -> {declared, rest}
        {_, declared} -> {declared, nodes}
      end

    %{
      title: title,
      slug: presence(front_matter["slug"]),
      excerpt: presence(front_matter["excerpt"]) || presence(front_matter["description"]),
      front_matter: front_matter,
      blocks: nodes |> render([]) |> Html.to_blocks(html_opts(opts))
    }
  end

  @doc """
  Split a leading front-matter block off `markdown`: `{fields, body}`.

  Only a block that *reads* as front matter is taken — `---` on the first
  line, a closing `---` (or `...`), and a `key: value` first entry. A document
  that merely opens with a horizontal rule followed by a setext heading keeps
  both. Values are unquoted; a `|` or `>` block value collects its indented
  lines. Nested YAML beyond that is not interpreted (its keys are skipped).
  """
  @spec split_front_matter(String.t()) :: {%{String.t() => String.t()}, String.t()}
  def split_front_matter(markdown) when is_binary(markdown) do
    source = String.replace_prefix(markdown, "﻿", "")

    # `Regex.run/2` omits a trailing group that did not participate, so empty
    # front matter (`---\n---`) arrives as a one-element list.
    with [whole | inner] <-
           Regex.run(~r/\A---[ \t]*\r?\n(?:(.*?)\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|\z)/s, source),
         {:ok, fields} <- front_matter_fields(List.first(inner, "")) do
      {fields, binary_part(source, byte_size(whole), byte_size(source) - byte_size(whole))}
    else
      _ -> {%{}, markdown}
    end
  end

  # ── Front matter ───────────────────────────────────────────────────────────

  defp front_matter_fields(inner) do
    lines = String.split(inner, ~r/\r?\n/)

    case Enum.find(lines, &(String.trim(&1) != "" and not String.starts_with?(&1, "#"))) do
      nil ->
        {:ok, %{}}

      first ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+:/, first),
          do: {:ok, collect_fields(lines, %{})},
          else: :error
    end
  end

  defp collect_fields([], acc), do: acc

  defp collect_fields([line | rest], acc) do
    case Regex.run(~r/\A([A-Za-z0-9_-]+):[ \t]*(.*?)[ \t]*\z/, line) do
      [_, key, marker] when marker in ["|", "|-", ">", ">-"] ->
        {block, rest} =
          Enum.split_while(rest, &(&1 == "" or String.starts_with?(&1, [" ", "\t"])))

        joiner = if String.starts_with?(marker, "|"), do: "\n", else: " "
        value = block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(joiner)
        collect_fields(rest, Map.put(acc, String.downcase(key), value))

      [_, key, value] ->
        collect_fields(rest, Map.put(acc, String.downcase(key), unquote_value(value)))

      _ ->
        collect_fields(rest, acc)
    end
  end

  defp unquote_value(value) do
    case Regex.run(~r/\A(["'])(.*)\1\z/s, value) do
      [_, "\"", inner] -> String.replace(inner, ~s(\\"), ~s("))
      [_, "'", inner] -> String.replace(inner, "''", "'")
      _ -> value
    end
  end

  defp leading_h1([{"h1", _attrs, children, _meta} | rest]) do
    case children |> plain_text() |> String.trim() do
      "" -> nil
      heading -> {heading, rest}
    end
  end

  defp leading_h1(_nodes), do: nil

  # ── Parsing ────────────────────────────────────────────────────────────────

  defp parse(markdown) do
    # `{:error, ast, messages}` is earmark's "parsed, with warnings" (an
    # unclosed fence, a stray `]`). The tree is still the author's document;
    # refusing it would turn a typo into a lost paste.
    ast =
      case EarmarkParser.as_ast(markdown, gfm_tables: true, breaks: false, pure_links: true) do
        {:ok, ast, _messages} -> ast
        {:error, ast, _messages} -> ast
      end

    # A no-op at runtime, there for dialyzer: earmark's success typing
    # narrows the tree to `[binary()]` (its own spec says nodes may be
    # tuples — and they are), which marks every element clause in this module
    # unmatchable. Widening here keeps those clauses checked, where an ignore
    # entry would hide real pattern bugs in this file too.
    Enum.to_list(ast)
  end

  # Markdown is not WordPress: `autop` would re-wrap paragraphs Markdown
  # already marked, and the shortcode passes would delete prose such as
  # `[x=1]` or a literal `[embed]`.
  defp html_opts(opts),
    do: opts |> Keyword.take([:media_resolver]) |> Keyword.merge(autop: false, shortcodes: false)

  # ── Rendering ──────────────────────────────────────────────────────────────

  # The space between two inline siblings (`**a** *b*`) is a text node of its
  # own, and the HTML parser downstream DROPS whitespace-only text nodes — so
  # "a b" arrived as "ab". A no-break space is not whitespace to that parser,
  # and `KilnCMS.Blocks.Html` normalizes it back to an ordinary space.
  defp render(nodes, opts) when is_list(nodes) do
    last = length(nodes) - 1

    nodes
    |> Enum.with_index()
    |> Enum.map_join(fn
      {text, index} when is_binary(text) and index > 0 and index < last ->
        if String.trim(text) == "", do: " ", else: render_node(text, opts)

      {node, _index} ->
        render_node(node, opts)
    end)
  end

  defp render_node(text, _opts) when is_binary(text), do: text_html(text)

  # An HTML comment: `{:comment, [], [lines], %{comment: true}}`, whose tag is
  # the ATOM `:comment` and so matches none of the tag lists above. Its text is
  # a note to whoever edits the file, never content — without this the catch-all
  # at the bottom would render it as a paragraph of visible prose. A comment
  # written mid-sentence never reaches here: it stays inside the paragraph's
  # text run, where `text_html/1` hands it to the sanitizer, which drops it.
  defp render_node({_tag, _attrs, _children, %{comment: true}}, _opts), do: ""

  defp render_node({tag, _attrs, _children, %{verbatim: true}}, _opts)
       when tag in @dropped_raw,
       do: ""

  # An HTML block the author wrote. Reassembled and handed to the sanitizer
  # whole, so its allowlist — not this module — decides what survives.
  defp render_node({tag, attrs, children, %{verbatim: true}}, _opts) when is_binary(tag) do
    raw =
      "<#{tag}#{raw_attrs(attrs)}>" <>
        Enum.map_join(children, "\n", &verbatim_line/1) <> "</#{tag}>"

    HTMLSanitizer.sanitize_rich_text(raw)
  end

  defp render_node({"pre", _attrs, children, _meta}, _opts) do
    {language, text} =
      case children do
        [{"code", attrs, kids, _meta}] -> {code_language(attrs), plain_text(kids)}
        kids -> {nil, plain_text(kids)}
      end

    class = if language, do: ~s( class="language-#{escape(language)}"), else: ""
    "<pre><code#{class}>" <> escape(text) <> "</code></pre>"
  end

  defp render_node({"code", _attrs, children, _meta}, _opts),
    do: "<code>" <> escape(plain_text(children)) <> "</code>"

  defp render_node({"a", attrs, children, _meta}, opts) do
    case attrs |> attr("href") |> HTMLSanitizer.safe_href() do
      nil -> render(children, opts)
      href -> ~s(<a href="#{escape(href)}">) <> render(children, opts) <> "</a>"
    end
  end

  defp render_node({"img", attrs, _children, _meta}, opts) do
    src = attrs |> attr("src") |> HTMLSanitizer.safe_image_src()
    alt = attr(attrs, "alt")

    cond do
      # An unusable URL: the alt text is still the author's words.
      is_nil(src) ->
        escape(alt || "")

      Keyword.get(opts, :images, :keep) == :link ->
        ~s(<a href="#{escape(src)}">) <> escape(presence(alt) || src) <> "</a>"

      true ->
        title = attr(attrs, "title")
        title_attr = if presence(title), do: ~s( title="#{escape(title)}"), else: ""
        ~s(<img src="#{escape(src)}" alt="#{escape(alt || "")}"#{title_attr}>)
    end
  end

  defp render_node({tag, _attrs, children, _meta}, opts) when tag in @plain_tags,
    do: "<#{tag}>" <> render(children, opts) <> "</#{tag}>"

  defp render_node({tag, _attrs, _children, _meta}, _opts) when tag in @void_tags, do: "<#{tag}>"

  # Anything else (an element this list does not know): its text is still the
  # author's, the wrapper is not trusted.
  defp render_node({_tag, _attrs, children, _meta}, opts) when is_list(children),
    do: render(children, opts)

  defp render_node(_other, _opts), do: ""

  # A text run. earmark leaves inline HTML (`<kbd>`, `<br>`, `<b>`) inside the
  # text, unescaped — which Markdown means as HTML — so a run that could hold
  # a tag goes through the sanitizer; everything else is escaped here.
  #
  # Character references are decoded FIRST, by this module. Left for the HTML
  # parser, a named one came back as U+FFFD (`&copy;` → `�`): mochiweb, under
  # both Floki and the sanitizer, does not decode them to UTF-8. On the
  # sanitizer path the markup-significant ones (`&lt;` …) stay encoded, or
  # decoding them would conjure tags the author escaped on purpose.
  #
  # `<script>` and friends inside a run lose their CONTENT here too: the
  # sanitizer drops the tags but keeps `alert(1)` as visible prose.
  defp text_html(text) do
    if Regex.match?(~r{<[A-Za-z/!?]}, text),
      do:
        text
        |> String.replace(~r{<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>}is, "")
        |> decode_entities(false)
        |> HTMLSanitizer.sanitize_rich_text(),
      else: text |> decode_entities(true) |> escape_text()
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @markup_chars ["<", ">", "&", ~s("), "'"]

  # The references Markdown prose actually uses. Anything else is left as the
  # author typed it — visible `&foo;` beats a guess.
  @named_entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => ~s("),
    "apos" => "'",
    "nbsp" => " ",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "laquo" => "«",
    "raquo" => "»",
    "middot" => "·",
    "bull" => "•",
    "deg" => "°",
    "times" => "×",
    "divide" => "÷",
    "plusmn" => "±",
    "sect" => "§",
    "para" => "¶",
    "euro" => "€",
    "pound" => "£",
    "yen" => "¥",
    "cent" => "¢",
    "larr" => "←",
    "rarr" => "→",
    "uarr" => "↑",
    "darr" => "↓",
    "harr" => "↔",
    "le" => "≤",
    "ge" => "≥",
    "ne" => "≠",
    "frac12" => "½",
    "frac14" => "¼",
    "frac34" => "¾"
  }

  defp decode_entities(text, markup?) do
    Regex.replace(
      ~r/&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/,
      text,
      &decode_entity(&1, &2, markup?)
    )
  end

  defp decode_entity(whole, ref, markup?) do
    case entity_char(ref) do
      nil -> whole
      char -> if markup? or char not in @markup_chars, do: char, else: whole
    end
  end

  defp entity_char("#" <> <<x, hex::binary>>) when x in [?x, ?X],
    do: codepoint(String.to_integer(hex, 16))

  defp entity_char("#" <> decimal), do: codepoint(String.to_integer(decimal))
  defp entity_char(name), do: Map.get(@named_entities, name)

  # NUL, surrogates and out-of-range values are not characters; the reference
  # stays literal rather than becoming invalid UTF-8.
  defp codepoint(n) when n in 1..0xD7FF or n in 0xE000..0x10FFFF, do: <<n::utf8>>
  defp codepoint(_n), do: nil

  defp verbatim_line(line) when is_binary(line), do: line
  defp verbatim_line(_other), do: ""

  # Attributes of a raw HTML block, re-escaped on the way back into a tag so a
  # value cannot close its quote. The sanitizer then drops whatever it
  # doesn't allow.
  defp raw_attrs(attrs) do
    Enum.map_join(attrs, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_:-]*\z/, name),
          do: ~s( #{name}="#{escape(decode(value))}"),
          else: ""

      _ ->
        ""
    end)
  end

  # earmark tags a fence as `class="elixir"`; `KilnCMS.Blocks.Html` reads the
  # `language-` convention. An info string with more than a language
  # (```` ```elixir title=x ````) keeps its first word.
  defp code_language(attrs) do
    with class when is_binary(class) <- attr(attrs, "class"),
         [first | _] <- String.split(class),
         language = String.replace_prefix(first, "language-", ""),
         true <- Regex.match?(~r/\A[A-Za-z0-9_+#-]{1,40}\z/, language) do
      language
    else
      _ -> nil
    end
  end

  defp plain_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(text) when is_binary(text), do: text
  defp plain_text({_tag, _attrs, children, _meta}), do: plain_text(children)
  defp plain_text(_other), do: ""

  # earmark pre-escapes some attribute values (`alt`) and not others (`href`),
  # so every value is decoded before it is escaped exactly once.
  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} when is_binary(value) -> decode(value)
      _ -> nil
    end)
  end

  defp decode(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
