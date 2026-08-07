defmodule KilnCMS.Blocks.Html do
  @moduledoc """
  Legacy HTML → structured content (#487) — the direction
  `KilnCMS.Blocks.PortableText` does not go.

  Every importer faces the same problem: the source system stores a document
  body as a blob of HTML, and this CMS stores typed blocks whose prose is
  Portable Text. This module is that adapter, and it is deliberately the *only*
  place HTML is read back into structure, so an importer for Ghost or Drupal
  reuses it rather than growing a second dialect.

  ## The route

  HTML is converted to **TipTap JSON** and handed to
  `PortableText.from_tiptap/1` rather than built into Portable Text directly.
  TipTap is already the interchange layer this codebase converts *from*, so
  routing through it means marks, nested lists, tables and link `markDefs` are
  produced by the one implementation that delivery, search and the editor
  already agree on — an HTML-specific PT builder would be a second thing to
  keep in step, and the two would drift on exactly the edge cases (nested list
  levels, `markDefs` keys) that are hardest to notice.

  ## `to_blocks/2` vs `to_portable_text/2`

  Prose is not all a body holds. `to_portable_text/2` answers "what is the text
  here" and drops everything that is not prose. `to_blocks/2` is what an
  importer wants: it walks the top level and splits the document into a
  sequence of typed blocks — prose runs become `rich_text`, a standalone image
  becomes an `image` block, an iframe or bare video URL becomes an `embed` —
  so an imported post lands as something an editor can actually edit, not one
  opaque slab of text with its images silently gone.

  ## WordPress-shaped input

  Two habits of WordPress bodies are handled here rather than in the importer,
  because any HTML of that vintage has them:

    * **`wpautop`.** Classic-editor content has *no* `<p>` tags — paragraphs are
      blank lines, and WordPress wraps them at render time. Parsing that HTML
      literally yields one enormous paragraph. `:autop` (default `true`)
      reproduces the wrapping first.
    * **Gutenberg delimiters.** Block-editor content is ordinary HTML fenced by
      `<!-- wp:paragraph -->` comments. The comments carry no text, so they are
      stripped; the HTML inside them converts normally.

  Shortcodes are handled to the extent that they carry content a reader would
  miss: `[caption]` becomes the image's caption, `[embed]` becomes an embed
  block, and every other shortcode is removed rather than left as literal
  `[gallery ids="..."]` text in the middle of a paragraph.
  """

  alias KilnCMS.Blocks.PortableText

  # Tags that force a paragraph break in `autop/1`, mirroring wpautop's list.
  @block_tags ~w(
    address article aside blockquote canvas dd div dl dt fieldset figcaption
    figure footer form h1 h2 h3 h4 h5 h6 header hr li main nav noscript ol p
    pre section table tbody td tfoot th thead tr ul video
  )

  # Containers that contribute their children to the enclosing level rather
  # than a block of their own.
  @transparent ~w(div section article main header footer aside body html nav)

  @heading_tags ~w(h1 h2 h3 h4 h5 h6)

  # Inline elements that carry a mark. `ins` is treated as underline and `del`
  # as strike, which is how both render by default in every browser.
  @marks %{
    "strong" => "bold",
    "b" => "bold",
    "em" => "italic",
    "i" => "italic",
    "code" => "code",
    "s" => "strike",
    "del" => "strike",
    "strike" => "strike",
    "u" => "underline",
    "ins" => "underline"
  }

  @typedoc "A typed-block input map, in the union's `type`/`value` storage shape."
  @type block_input :: %{required(String.t()) => term()}

  @doc """
  `html` as Portable Text blocks — prose only.

  Options:

    * `:autop` — reproduce WordPress' paragraph wrapping first (default `true`).
      Pass `false` for HTML that already marks its own paragraphs and whose
      blank lines are insignificant.
  """
  @spec to_portable_text(String.t() | nil, keyword()) :: [PortableText.pt_block()]
  def to_portable_text(html, opts \\ [])
  def to_portable_text(nil, _opts), do: []

  def to_portable_text(html, opts) when is_binary(html) do
    html |> to_tiptap(opts) |> PortableText.from_tiptap()
  end

  @doc """
  `html` as a TipTap document map (`%{"type" => "doc", "content" => [...]}`).

  Exposed because it is the shape the editor itself speaks: a caller that wants
  to hand imported prose straight to a TipTap instance needs this rather than
  the Portable Text it becomes on save. Same options as `to_portable_text/2`.
  """
  @spec to_tiptap(String.t() | nil, keyword()) :: map()
  def to_tiptap(html, opts \\ [])
  def to_tiptap(nil, _opts), do: %{"type" => "doc", "content" => []}

  def to_tiptap(html, opts) when is_binary(html) do
    %{"type" => "doc", "content" => html |> parse(opts) |> Enum.flat_map(&block_node/1)}
  end

  @doc """
  `html` split into typed blocks: prose runs as `rich_text`, standalone images
  as `image`, iframes and bare embeddable URLs as `embed`.

  The return value is a list of union **input** maps (`%{"type" => ..., "value"
  => ...}`), ready to pass as a create action's `blocks` argument.

  Options are those of `to_portable_text/2`, plus:

    * `:media_resolver` — `(src_url -> %{media_id: id, url: url} | nil)`, called
      for every image. An importer that sideloads media passes one so the block
      points at the `MediaItem` it created; without one the block keeps the
      source URL, which still renders but hotlinks the old site.
  """
  @spec to_blocks(String.t() | nil, keyword()) :: [block_input()]
  def to_blocks(html, opts \\ [])
  def to_blocks(nil, _opts), do: []

  def to_blocks(html, opts) when is_binary(html) do
    html
    |> parse(opts)
    |> Enum.flat_map(&split_top_level/1)
    |> group_runs()
    |> Enum.flat_map(&run_to_block(&1, opts))
    |> Enum.reject(&is_nil/1)
  end

  # ── Parsing ────────────────────────────────────────────────────────────────

  defp parse(html, opts) do
    html
    |> strip_gutenberg_comments()
    |> expand_captions()
    |> expand_embed_shortcodes()
    |> strip_shortcodes()
    |> maybe_autop(Keyword.get(opts, :autop, true))
    |> Floki.parse_fragment()
    |> case do
      {:ok, nodes} -> nodes
      # A fragment Floki cannot parse is not worth failing an import over —
      # the text is still recoverable, and losing formatting beats losing the
      # post. `parse_document` is far more forgiving (it repairs the tree).
      {:error, _reason} -> html |> Floki.parse_document() |> elem(1) |> List.wrap()
    end
  end

  # `<!-- wp:paragraph {"align":"left"} -->` and its closing form. The JSON
  # payload describes presentation the target blocks have no equivalent for,
  # so only the comment wrapper goes; the HTML between the delimiters stays.
  defp strip_gutenberg_comments(html),
    do: String.replace(html, ~r{<!--\s*/?wp:.*?-->}s, "")

  # `[caption id="…" width="…"]<img …/>Some caption[/caption]` — the caption is
  # bare text after the image, which would otherwise be parsed as a sibling
  # text node and land in the following paragraph. Rewrite to the `<figure>`
  # the same markup means today.
  defp expand_captions(html) do
    Regex.replace(~r{\[caption[^\]]*\](.*?)\[/caption\]}s, html, fn _full, inner ->
      case Regex.run(~r{(<img[^>]*>|<a[^>]*>.*?</a>)(.*)}s, inner) do
        [_, media, caption] ->
          "<figure>#{media}<figcaption>#{String.trim(caption)}</figcaption></figure>"

        _ ->
          inner
      end
    end)
  end

  # `[embed]https://…[/embed]` and `[video src="…"]` carry a URL a reader would
  # otherwise lose entirely. Promote to an anchor on its own line; the
  # top-level split turns a lone embeddable link into an `embed` block.
  defp expand_embed_shortcodes(html) do
    html
    |> String.replace(
      ~r{\[embed[^\]]*\]\s*(\S+?)\s*\[/embed\]}s,
      "\n\n<a href=\"\\1\">\\1</a>\n\n"
    )
    |> String.replace(
      ~r{\[(?:video|audio)[^\]]*\bsrc=["']([^"']+)["'][^\]]*\]},
      "\n\n<a href=\"\\1\">\\1</a>\n\n"
    )
  end

  # Everything else. Left in place these render as literal `[gallery ids="1,2"]`
  # text mid-paragraph, which is worse than absent: it looks like content.
  # Paired shortcodes keep their inner content, self-closing ones just go.
  defp strip_shortcodes(html) do
    html
    |> String.replace(~r{\[(\w[\w-]*)[^\]]*\](.*?)\[/\1\]}s, "\\2")
    |> String.replace(~r{\[/?\w[\w-]*[^\]]*\]}, "")
  end

  defp maybe_autop(html, false), do: html
  defp maybe_autop(html, _true), do: autop(html)

  @doc """
  WordPress' `wpautop`, closely enough: blank-line-separated runs of text
  become paragraphs and remaining single newlines become `<br />`.

  Public because it is the one transformation an importer may need to *skip*
  knowingly (a source that stores real `<p>` tags and meaningful whitespace),
  and skipping it should be a deliberate call rather than a hidden default.

  Runs that already begin with a block-level tag are passed through untouched,
  which is what makes this safe to apply to content that is already wrapped —
  the same property the original relies on.
  """
  @spec autop(String.t()) :: String.t()
  def autop(html) do
    {html, pres} = protect_pre(html)

    html
    |> String.replace("\r\n", "\n")
    |> break_around_blocks()
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &wrap_run/1)
    |> restore_pre(pres)
  end

  # `<pre>` is the one element where newlines are content. Swap each occurrence
  # out for a positional placeholder before the newline rewriting and put it
  # back after. The token is indexed rather than content-hashed so two
  # identical code blocks in one document stay two blocks.
  defp protect_pre(html) do
    {parts, replaced} =
      ~r{<pre\b.*?</pre>}s
      |> Regex.scan(html)
      |> Enum.with_index()
      |> Enum.reduce({[], html}, fn {[match], idx}, {parts, acc} ->
        token = "<!--kiln-pre-#{idx}-->"
        # `replace/4` with `global: false` so only THIS occurrence is consumed;
        # the next identical match then finds the following one.
        {[{token, match} | parts], String.replace(acc, match, "\n\n#{token}\n\n", global: false)}
      end)

    {replaced, Enum.reverse(parts)}
  end

  defp restore_pre(html, parts) do
    Enum.reduce(parts, html, fn {token, original}, acc ->
      acc
      |> String.replace("<p>#{token}</p>", original)
      |> String.replace(token, original)
    end)
  end

  defp break_around_blocks(html) do
    Enum.reduce(@block_tags, html, fn tag, acc ->
      acc
      |> String.replace(~r{<#{tag}(\s[^>]*)?>}i, "\n\n<#{tag}\\1>")
      |> String.replace(~r{</#{tag}>}i, "</#{tag}>\n\n")
    end)
  end

  defp wrap_run(run) do
    if String.starts_with?(run, "<") and starts_with_block_tag?(run),
      do: run,
      else: "<p>" <> String.replace(run, "\n", "<br />") <> "</p>"
  end

  defp starts_with_block_tag?(run) do
    case Regex.run(~r{^</?([a-zA-Z0-9]+)}, run) do
      [_, tag] -> String.downcase(tag) in @block_tags or String.downcase(tag) == "!--"
      _ -> String.starts_with?(run, "<!--")
    end
  end

  # ── Top-level split (to_blocks/2) ──────────────────────────────────────────

  # A transparent container contributes its children to the top level, so an
  # image wrapped in the `<div>` WordPress emits still becomes its own block.
  defp split_top_level({tag, _attrs, children}) when tag in @transparent,
    do: Enum.flat_map(children, &split_top_level/1)

  defp split_top_level({"figure", _attrs, children} = node) do
    case figure_parts(children) do
      {nil, _caption} -> [{:prose, node}]
      {media, caption} -> [{:media, media, caption}]
    end
  end

  defp split_top_level({"img", _attrs, _} = node), do: [{:media, node, nil}]
  defp split_top_level({"iframe", _attrs, _} = node), do: [{:media, node, nil}]

  # A paragraph whose entire content is one image or one link to an embeddable
  # URL is that thing, not prose about it — this is how both classic WordPress
  # and Gutenberg emit a standalone image or an auto-embedded video.
  defp split_top_level({"p", _attrs, children} = node) do
    case Enum.reject(children, &blank_text?/1) do
      [{"img", _, _} = img] -> [{:media, img, nil}]
      # `autop/1` treats `iframe` as inline and wraps a lone one in a `<p>`.
      # Without this clause the paragraph converts to no inline content at all
      # and the whole embed is dropped silently — the only failure mode here
      # that loses a whole element rather than its formatting.
      [{"iframe", _, _} = frame] -> [{:media, frame, nil}]
      [{"a", _, _} = link] -> [link_only_paragraph(link, node)]
      [text] when is_binary(text) -> [bare_url_paragraph(text, node)]
      _ -> [{:prose, node}]
    end
  end

  defp split_top_level(node), do: [{:prose, node}]

  defp link_only_paragraph({"a", attrs, children} = link, node) do
    href = attr(attrs, "href")

    cond do
      # `<a href="…"><img …></a>` — a linked image is still an image block.
      Enum.any?(children, &match?({"img", _, _}, &1)) ->
        {:media, Enum.find(children, &match?({"img", _, _}, &1)), nil}

      embeddable?(href) and link_text_is_url?(link, href) ->
        {:embed, href}

      true ->
        {:prose, node}
    end
  end

  defp bare_url_paragraph(text, node) do
    trimmed = String.trim(text)

    if embeddable?(trimmed), do: {:embed, trimmed}, else: {:prose, node}
  end

  # Only treat the link as an embed when it is *bare* — an anchor whose text is
  # its own href is WordPress' auto-embed marker. A link with real anchor text
  # is a sentence the author wrote, and turning it into a video player would
  # discard their words.
  defp link_text_is_url?(link, href) do
    text = link |> Floki.text() |> String.trim()
    text == "" or text == href
  end

  defp figure_parts(children) do
    flat = List.flatten(collect_descendants(children))

    media =
      Enum.find(flat, fn
        {tag, _, _} -> tag in ["img", "iframe"]
        _ -> false
      end)

    caption =
      case Enum.find(flat, &match?({"figcaption", _, _}, &1)) do
        nil -> nil
        node -> node |> Floki.text() |> String.trim() |> presence()
      end

    {media, caption}
  end

  defp collect_descendants(nodes) do
    Enum.flat_map(List.wrap(nodes), fn
      {_tag, _attrs, children} = node -> [node | collect_descendants(children)]
      _other -> []
    end)
  end

  # Consecutive prose nodes become ONE rich_text block. Emitting one block per
  # paragraph would turn a ten-paragraph post into ten blocks the editor has to
  # scroll past, and would break prose that PT represents as sibling blocks
  # (list items, table rows) into unrelated islands.
  defp group_runs(items) do
    items
    |> Enum.chunk_by(&match?({:prose, _}, &1))
    |> Enum.map(fn
      [{:prose, _} | _] = prose -> {:prose_run, Enum.map(prose, fn {:prose, n} -> n end)}
      other -> other
    end)
    |> Enum.flat_map(fn
      {:prose_run, _} = run -> [run]
      list -> list
    end)
  end

  defp run_to_block({:prose_run, nodes}, _opts) do
    body =
      %{"type" => "doc", "content" => Enum.flat_map(nodes, &block_node/1)}
      |> PortableText.from_tiptap()
      |> PortableText.sanitize_body()

    if prose_empty?(body), do: [], else: [%{"type" => "rich_text", "value" => %{"body" => body}}]
  end

  defp run_to_block({:media, {"iframe", attrs, _}, _caption}, _opts) do
    case attr(attrs, "src") do
      nil -> []
      src -> [%{"type" => "embed", "value" => %{"url" => src}}]
    end
  end

  defp run_to_block({:media, {"img", attrs, _}, caption}, opts) do
    case attr(attrs, "src") do
      nil ->
        []

      src ->
        resolved = resolve_media(src, opts)

        value =
          %{
            "url" => resolved[:url] || src,
            "alt" => attr(attrs, "alt"),
            "caption" => caption || presence(attr(attrs, "title"))
          }
          |> put_present("media_id", resolved[:media_id])

        [%{"type" => "image", "value" => value}]
    end
  end

  defp run_to_block({:media, _node, _caption}, _opts), do: []
  defp run_to_block({:embed, url}, _opts), do: [%{"type" => "embed", "value" => %{"url" => url}}]
  defp run_to_block(_other, _opts), do: []

  defp resolve_media(src, opts) do
    case Keyword.get(opts, :media_resolver) do
      fun when is_function(fun, 1) -> fun.(src) || %{}
      _ -> %{}
    end
  end

  # A run that converted to nothing but empty spans is whitespace the source
  # had between two images — emitting a rich_text block for it would leave an
  # empty prose box in the editor between every picture.
  defp prose_empty?(body) do
    body
    |> PortableText.to_plain_text()
    |> String.trim()
    |> Kernel.==("")
  end

  # ── HTML → TipTap: block level ─────────────────────────────────────────────

  defp block_node({tag, _attrs, children}) when tag in @transparent,
    do: Enum.flat_map(children, &block_node/1)

  defp block_node({"p", _attrs, children}),
    do: [%{"type" => "paragraph", "content" => inline(children, [])}]

  defp block_node({tag, _attrs, children}) when tag in @heading_tags do
    level = tag |> String.trim_leading("h") |> String.to_integer()
    [%{"type" => "heading", "attrs" => %{"level" => level}, "content" => inline(children, [])}]
  end

  defp block_node({"ul", _attrs, children}), do: [list_node("bulletList", children)]
  defp block_node({"ol", _attrs, children}), do: [list_node("orderedList", children)]

  defp block_node({"blockquote", _attrs, children}) do
    inner = Enum.flat_map(children, &block_node/1)
    content = if inner == [], do: [%{"type" => "paragraph", "content" => []}], else: inner
    [%{"type" => "blockquote", "content" => content}]
  end

  defp block_node({"pre", _attrs, children}) do
    {text, language} = code_parts(children)

    node = %{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => text}]}
    [if(language, do: Map.put(node, "attrs", %{"language" => language}), else: node)]
  end

  defp block_node({"hr", _attrs, _children}), do: [%{"type" => "horizontalRule"}]

  defp block_node({"table", _attrs, children}) do
    rows =
      children
      |> collect_descendants()
      |> Enum.filter(&match?({"tr", _, _}, &1))
      |> Enum.map(&table_row/1)

    if rows == [], do: [], else: [%{"type" => "table", "content" => rows}]
  end

  defp block_node({"figure", _attrs, children}) do
    # In prose position a figure is its caption plus whatever prose it holds —
    # the image itself has no TipTap equivalent `from_tiptap/1` understands, so
    # it is `to_blocks/2`'s job, not this one's.
    Enum.flat_map(children, fn
      {"figcaption", _, kids} -> [%{"type" => "paragraph", "content" => inline(kids, [])}]
      {tag, _, _} = node when tag not in ["img", "iframe"] -> block_node(node)
      _ -> []
    end)
  end

  defp block_node({"br", _attrs, _children}), do: []
  defp block_node({tag, _attrs, _children}) when tag in ["script", "style", "noscript"], do: []
  defp block_node({:comment, _}), do: []

  # A bare text node at block level (an unwrapped run when `:autop` is off).
  defp block_node(text) when is_binary(text) do
    case String.trim(text) do
      "" -> []
      _ -> [%{"type" => "paragraph", "content" => inline([text], [])}]
    end
  end

  # Any other element in block position — an inline tag stranded at the top
  # level, or a tag this converter has no mapping for. Its text is still the
  # author's, so it becomes a paragraph rather than nothing.
  defp block_node({_tag, _attrs, children} = node) do
    case inline([node], []) do
      [] -> Enum.flat_map(children, &block_node/1)
      content -> [%{"type" => "paragraph", "content" => content}]
    end
  end

  defp block_node(_other), do: []

  defp list_node(type, children) do
    items =
      children
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.map(fn {"li", _, kids} -> %{"type" => "listItem", "content" => list_item(kids)} end)

    %{"type" => type, "content" => items}
  end

  # A list item's own text is not always wrapped in a `<p>`; TipTap requires
  # block content, so loose inline children are gathered into one paragraph and
  # nested lists are kept as siblings (which is how nesting reaches PT `level`).
  defp list_item(children) do
    {inline_kids, block_kids} = Enum.split_with(children, &inline_node?/1)

    leading =
      case inline(inline_kids, []) do
        [] -> []
        content -> [%{"type" => "paragraph", "content" => content}]
      end

    nested = Enum.flat_map(block_kids, &block_node/1)

    case leading ++ nested do
      [] -> [%{"type" => "paragraph", "content" => []}]
      content -> content
    end
  end

  defp inline_node?(node) when is_binary(node), do: true
  defp inline_node?({tag, _, _}) when tag in ["ul", "ol", "p", "div", "blockquote"], do: false
  defp inline_node?({tag, _, _}) when is_binary(tag), do: tag not in @block_tags
  defp inline_node?(_other), do: false

  defp table_row({"tr", _attrs, children}) do
    cells =
      children
      |> Enum.filter(&match?({tag, _, _} when tag in ["td", "th"], &1))
      |> Enum.map(&table_cell/1)

    %{"type" => "tableRow", "content" => cells}
  end

  defp table_cell({tag, attrs, children}) do
    type = if tag == "th", do: "tableHeader", else: "tableCell"

    content =
      case Enum.flat_map(children, &block_node/1) do
        [] -> [%{"type" => "paragraph", "content" => []}]
        blocks -> blocks
      end

    %{"type" => type, "attrs" => cell_attrs(attrs), "content" => content}
  end

  defp cell_attrs(attrs) do
    %{}
    |> put_span(attrs, "colspan")
    |> put_span(attrs, "rowspan")
  end

  defp put_span(acc, attrs, key) do
    case attrs |> attr(key) |> to_int() do
      n when is_integer(n) and n > 1 -> Map.put(acc, key, n)
      _ -> acc
    end
  end

  # `<pre><code class="language-elixir">` is the near-universal convention;
  # WordPress also emits `class="brush: elixir"`. Anything unrecognised is
  # dropped rather than stored, matching how the editor treats a bad tag.
  defp code_parts(children) do
    case Enum.find(children, &match?({"code", _, _}, &1)) do
      {"code", attrs, kids} -> {Floki.text(kids), language_from(attrs)}
      _ -> {Floki.text(children), nil}
    end
  end

  defp language_from(attrs) do
    class = attr(attrs, "class") || ""

    candidate =
      case Regex.run(~r/(?:language|lang|brush:?)[-\s]*([a-zA-Z0-9_+#-]+)/, class) do
        [_, lang] -> lang
        _ -> nil
      end

    candidate && KilnCMS.Highlight.normalize(candidate)
  end

  # ── HTML → TipTap: inline level ────────────────────────────────────────────

  defp inline(nodes, marks) do
    nodes
    |> List.wrap()
    |> Enum.flat_map(&inline_node(&1, marks))
    |> merge_adjacent()
  end

  defp inline_node(text, marks) when is_binary(text) do
    case normalize_space(text) do
      "" -> []
      normalized -> [text_node(normalized, marks)]
    end
  end

  defp inline_node({"br", _attrs, _}, _marks), do: [%{"type" => "hardBreak"}]

  defp inline_node({"a", attrs, children}, marks) do
    case attr(attrs, "href") do
      nil -> inline(children, marks)
      href -> inline(children, [%{"type" => "link", "attrs" => %{"href" => href}} | marks])
    end
  end

  defp inline_node({tag, _attrs, children}, marks) when is_map_key(@marks, tag),
    do: inline(children, [%{"type" => Map.fetch!(@marks, tag)} | marks])

  defp inline_node({tag, _attrs, _children}, _marks)
       when tag in ["script", "style", "noscript", "img", "iframe"],
       do: []

  defp inline_node({_tag, _attrs, children}, marks), do: inline(children, marks)
  defp inline_node(_other, _marks), do: []

  defp text_node(text, []), do: %{"type" => "text", "text" => text}

  defp text_node(text, marks),
    do: %{"type" => "text", "text" => text, "marks" => Enum.uniq_by(marks, & &1["type"])}

  # Two text nodes with identical marks came from sibling tags that meant one
  # run (`<b>a</b><b>b</b>`); leaving them split multiplies spans in the stored
  # PT for no difference in meaning.
  defp merge_adjacent(nodes) do
    Enum.reduce(nodes, [], fn
      %{"type" => "text"} = node, [%{"type" => "text"} = prev | rest] ->
        if Map.get(node, "marks", []) == Map.get(prev, "marks", []),
          do: [%{prev | "text" => prev["text"] <> node["text"]} | rest],
          else: [node, prev | rest]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end

  # HTML collapses runs of whitespace, including the newlines `autop/1` left
  # behind inside a wrapped run. Without this every imported paragraph carries
  # the source file's line breaks as literal spaces.
  defp normalize_space(text), do: String.replace(text, ~r/\s+/u, " ")

  # ── Small helpers ──────────────────────────────────────────────────────────

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp blank_text?(node) when is_binary(node), do: String.trim(node) == ""
  defp blank_text?({:comment, _}), do: true
  defp blank_text?(_other), do: false

  defp embeddable?(nil), do: false

  defp embeddable?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        # Deliberately narrow: the same two providers the embed block's own URL
        # sanitizer will accept. Anything else stays a link in the prose, which
        # is lossless — an embed block would blank an unrecognised URL on save.
        String.contains?(host, "youtube.com") or String.contains?(host, "youtu.be") or
          String.contains?(host, "vimeo.com")

      _ ->
        false
    end
  end

  defp embeddable?(_other), do: false

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp to_int(nil), do: nil

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(_other), do: nil
end
