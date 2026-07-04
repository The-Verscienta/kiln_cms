defmodule ShowcaseWeb.Blocks do
  @moduledoc """
  Renders KilnCMS `json`-surface content blocks into HTML on the BEAM.

  This is the point of the showcase: KilnCMS hands a frontend a **typed block
  tree** (not baked HTML), and the frontend renders it however it likes. Here we
  turn each block into semantic markup and interpret the Portable-Text-style
  rich-text spans (marks + link annotations) ourselves.

  Unknown block types are skipped, so content using custom/plugin blocks this
  example doesn't know about degrades gracefully rather than crashing.
  """
  use ShowcaseWeb, :html

  attr :blocks, :list, default: []

  def content(assigns) do
    ~H"""
    <div class="article">
      <.block :for={block <- @blocks} block={block} />
    </div>
    """
  end

  # ── one block per type ──────────────────────────────────────────────────────

  attr :block, :map, required: true

  def block(%{block: %{"_type" => "heading"}} = assigns) do
    ~H"""
    <.heading level={@block["level"] || 2} text={@block["text"]} />
    """
  end

  def block(%{block: %{"_type" => "rich_text"}} = assigns) do
    ~H"""
    <.pt_block :for={ptb <- @block["body"] || []} block={ptb} />
    """
  end

  def block(%{block: %{"_type" => "image"}} = assigns) do
    ~H"""
    <figure>
      <img src={@block["url"]} alt={@block["alt"] || ""} loading="lazy" />
      <figcaption :if={@block["caption"]}>{@block["caption"]}</figcaption>
    </figure>
    """
  end

  def block(%{block: %{"_type" => "quote"}} = assigns) do
    ~H"""
    <blockquote>
      <span>{@block["text"]}</span>
      <cite :if={@block["citation"]}>{@block["citation"]}</cite>
    </blockquote>
    """
  end

  def block(%{block: %{"_type" => "divider"}} = assigns) do
    ~H"""
    <hr />
    """
  end

  def block(%{block: %{"_type" => "embed"}} = assigns) do
    ~H"""
    <div class="embed">
      <iframe
        src={@block["url"]}
        title="Embedded media"
        allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"
      ></iframe>
    </div>
    """
  end

  # Unknown block type — render nothing.
  def block(assigns), do: ~H""

  # ── headings ────────────────────────────────────────────────────────────────

  attr :level, :integer, default: 2
  attr :text, :string, default: ""

  def heading(assigns) do
    # Clamp to a real heading level; the page <h1> is the document title.
    assigns = assign(assigns, :level, min(max(assigns.level, 1), 6))

    ~H"""
    <h1 :if={@level == 1}>{@text}</h1>
    <h2 :if={@level == 2}>{@text}</h2>
    <h3 :if={@level == 3}>{@text}</h3>
    <h4 :if={@level == 4}>{@text}</h4>
    <h5 :if={@level == 5}>{@text}</h5>
    <h6 :if={@level == 6}>{@text}</h6>
    """
  end

  # ── portable text (rich_text body) ──────────────────────────────────────────

  attr :block, :map, required: true

  def pt_block(assigns) do
    assigns =
      assign(assigns,
        style: assigns.block["style"] || "normal",
        children: assigns.block["children"] || [],
        mark_defs: index_mark_defs(assigns.block["markDefs"])
      )

    ~H"""
    <h2 :if={@style == "h2"}><.spans children={@children} mark_defs={@mark_defs} /></h2>
    <h3 :if={@style == "h3"}><.spans children={@children} mark_defs={@mark_defs} /></h3>
    <h4 :if={@style == "h4"}><.spans children={@children} mark_defs={@mark_defs} /></h4>
    <blockquote :if={@style == "blockquote"}>
      <.spans children={@children} mark_defs={@mark_defs} />
    </blockquote>
    <p :if={@style not in ["h2", "h3", "h4", "blockquote"]}>
      <.spans children={@children} mark_defs={@mark_defs} />
    </p>
    """
  end

  attr :children, :list, default: []
  attr :mark_defs, :map, default: %{}

  def spans(assigns) do
    ~H"""
    <.marks
      :for={span <- @children}
      marks={span["marks"] || []}
      text={span["text"] || ""}
      mark_defs={@mark_defs}
    />
    """
  end

  # Recursively wrap a span's text in one element per mark (decorators like
  # strong/em/code, or a link annotation keyed into markDefs).
  attr :marks, :list, default: []
  attr :text, :string, default: ""
  attr :mark_defs, :map, default: %{}

  def marks(%{marks: []} = assigns) do
    ~H"{@text}"
  end

  def marks(%{marks: [mark | rest]} = assigns) do
    assigns = assign(assigns, mark: mark, rest: rest, link: assigns.mark_defs[mark])

    ~H"""
    <a :if={@link} href={@link["href"]} rel="noopener">
      <.marks marks={@rest} text={@text} mark_defs={@mark_defs} />
    </a>
    <strong :if={!@link and @mark == "strong"}>
      <.marks marks={@rest} text={@text} mark_defs={@mark_defs} />
    </strong>
    <em :if={!@link and @mark == "em"}>
      <.marks marks={@rest} text={@text} mark_defs={@mark_defs} />
    </em>
    <code :if={!@link and @mark == "code"}>
      <.marks marks={@rest} text={@text} mark_defs={@mark_defs} />
    </code>
    <u :if={!@link and @mark == "underline"}>
      <.marks marks={@rest} text={@text} mark_defs={@mark_defs} />
    </u>
    <.marks
      :if={!@link and @mark not in ["strong", "em", "code", "underline"]}
      marks={@rest}
      text={@text}
      mark_defs={@mark_defs}
    />
    """
  end

  # markDefs is a list of `%{"_key" => key, "_type" => "link", "href" => …}`;
  # index it by `_key` so a span mark can look up its annotation.
  defp index_mark_defs(defs) when is_list(defs) do
    Map.new(defs, fn def -> {def["_key"], def} end)
  end

  defp index_mark_defs(_), do: %{}
end
