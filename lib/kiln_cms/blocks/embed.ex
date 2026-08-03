defmodule KilnCMS.Blocks.Embed do
  @moduledoc """
  An external media embed (Kiln v2 typed block — D10), with cached oEmbed
  metadata (#489).

  ## Two kinds of embed, and only one of them is an iframe

  `KilnCMS.HTMLSanitizer.safe_embed_url/1` recognises YouTube and Vimeo and
  rewrites them to a canonical player URL. Those, and only those, render as an
  `<iframe>` — a fixed allowlist of two hosts whose player URLs Kiln constructs
  itself, which is what makes framing them defensible.

  Everything else renders as a **card**: a link, a title, a provider, and
  optionally a thumbnail, from metadata `KilnCMS.OEmbed` resolved server-side.
  The provider's own `html` is never used; see that module on why.

  Before #489 there was no third state — an unrecognised URL produced
  `<figure data-url="…"></figure>` with nothing inside it, which no consumer
  rendered. That is still the fallback when nothing resolved (the feature is
  off, no provider claimed the URL, the fetch failed), so a card that cannot be
  built degrades to exactly the old behaviour rather than to an error.

  ## The metadata is a cache, and is treated as one

  `title`, `author_name`, `provider_name` and `thumbnail_url` are *stored*
  fields, resolved when the URL is set rather than when the block is rendered —
  a fetch per render is a fetch per page view, with the provider's uptime in
  front of the site's. `resolved_at` records when, so a refresh can tell what is
  stale; nothing here expires on its own.

  None of it is authoritative: `url` is the block, and every metadata field may
  be absent at any time.
  """
  use Kiln.Block

  block :embed do
    # Not required — an unparseable URL is blanked on save, so an empty embed is
    # a valid (no-op) placeholder. What is stored is what the author typed
    # (absolute http(s) only); which URLs may be *framed* is decided at render.
    field :url, :string
    # Cached oEmbed metadata (#489). All optional: an embed that resolved to
    # nothing renders the bare figure it always did.
    field :title, :string
    field :author_name, :string
    field :provider_name, :string
    field :thumbnail_url, :string
    # The URL the metadata above actually describes. Metadata is only shown when
    # this still matches `url` — an editor who pastes a different link into an
    # existing block would otherwise keep the first video's title and thumbnail
    # over the second one's href, forever, because nothing else notices that the
    # cached values became wrong.
    field :resolved_url, :string
    # ISO8601 of the last successful resolution, for staleness. A string rather
    # than a datetime because every other block field is a scalar the jsonb
    # round-trip carries unchanged.
    field :resolved_at, :string
  end

  # Match a plain variable, not %__MODULE__{} — see the note in divider.ex: the
  # block struct isn't available when these heads compile (clean-compile only).
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    cond do
      # The two framed hosts keep the iframe they already had.
      iframe = KilnCMS.HTMLSanitizer.safe_embed_url(block.url) ->
        [
          "<figure class=\"kiln-embed\"><iframe src=\"",
          esc(iframe),
          "\" loading=\"lazy\" allowfullscreen title=\"",
          esc(block.title || "Embedded media"),
          "\"></iframe></figure>"
        ]

      card?(block) ->
        card_html(block)

      true ->
        # `data-url` is what a headless consumer builds its own link from, so it
        # is filtered here too rather than trusted because storage filters it.
        # A block constructed in code, an older row written before that filter,
        # or an import all reach this line.
        url = KilnCMS.HTMLSanitizer.safe_external_url(block.url) || ""
        ["<figure class=\"kiln-embed\" data-url=\"", esc(url), "\"></figure>"]
    end
  end

  def render(block, :json) do
    %{"_type" => "embed", "url" => block.url}
    |> put_if("title", block.title)
    |> put_if("author_name", block.author_name)
    |> put_if("provider_name", block.provider_name)
    |> put_if("thumbnail_url", block.thumbnail_url)
    |> put_if("resolved_url", block.resolved_url)
    |> put_if("resolved_at", block.resolved_at)
  end

  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  # The resolved title and author are the only human-readable text an embed
  # has ever carried, so they are also the only thing search could match on.
  def search_text(block) do
    if fresh?(block),
      do: [block.title, block.author_name] |> Enum.reject(&blank?/1) |> Enum.join(" "),
      else: ""
  end

  @doc """
  The `:llm` surface: a Markdown link, so an extracting engine sees what the
  embed is rather than a bare URL with no text.
  """
  def to_markdown(block) do
    cond do
      blank?(block.url) -> ""
      card?(block) -> "[#{block.title}](#{block.url})"
      true -> "<#{block.url}>"
    end
  end

  @doc """
  Whether this block has enough resolved metadata to render a card: a title, and
  a URL the link sanitizer vouches for.

  Shared with `KilnCMSWeb.BlockComponents` so the fired artifact and the live
  site agree on when a card exists rather than each deciding — the way the two
  gallery/accordion renderers drifted in #482.
  """
  @spec card?(struct()) :: boolean()
  def card?(block) do
    not blank?(block.title) and fresh?(block) and
      not is_nil(KilnCMS.HTMLSanitizer.safe_href(block.url))
  end

  @doc """
  Whether the cached metadata still describes this block's current URL.

  `false` the moment an editor pastes a different link, which is what stops the
  previous target's title and thumbnail rendering over the new one's href until
  a resolve happens to catch up.
  """
  @spec fresh?(struct()) :: boolean()
  def fresh?(block), do: not blank?(block.resolved_url) and block.resolved_url == block.url

  # A link wrapping an optional thumbnail plus the title, with the provider as a
  # caption. No provider markup, no script, nothing that needs a sanitizer —
  # every value here is an escaped scalar, and the thumbnail was checked against
  # the provider's CDN allowlist when it was resolved.
  defp card_html(block) do
    href = KilnCMS.HTMLSanitizer.safe_href(block.url)

    # Rendered only when the sanitizer vouches for it. `|| ""` would emit
    # `src=""`, which several browsers resolve as a re-request of the current
    # document — and the HEEx twin drops the element entirely, so emitting one
    # here would also put the two renderers out of step.
    thumbnail =
      case KilnCMS.HTMLSanitizer.safe_image_src(block.thumbnail_url) do
        nil -> []
        src -> ["<img src=\"", esc(src), "\" alt=\"\" loading=\"lazy\"/>"]
      end

    byline =
      [block.provider_name, block.author_name]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" · ")

    caption =
      if byline == "",
        do: [],
        else: ["<span class=\"kiln-embed-byline\">", esc(byline), "</span>"]

    [
      "<figure class=\"kiln-embed kiln-embed-card\"><a href=\"",
      esc(href),
      "\" rel=\"noopener\">",
      thumbnail,
      "<span class=\"kiln-embed-title\">",
      esc(block.title),
      "</span>",
      caption,
      "</a></figure>"
    ]
  end

  defp put_if(map, _key, value) when value in [nil, ""], do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
