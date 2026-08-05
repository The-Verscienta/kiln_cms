defmodule Kiln.Advisory.Checks.LinkText do
  @moduledoc """
  Link text that doesn't say where it goes (#495).

  Screen-reader users navigate by pulling up a list of a page's links, out of
  the surrounding prose. In that list, five links reading "click here" are
  five identical entries — the sentence that made each one meaningful isn't
  there. WCAG 2.4.4 is the formal version; the practical version is that link
  text has to work when read alone.

  Three findings, because they need three different fixes:

    * `:link_text_empty` (`:error`) — a link with no text at all. Nothing to
      click, nothing to announce; usually an editing accident, and invisible
      in the editor because there's no glyph to see.
    * `:link_text_uninformative` (`:warning`) — "click here", "read more",
      "this". Reads fine in context and useless out of it.
    * `:link_text_bare_url` (`:warning`) — the URL as its own label. A screen
      reader may read it character by character, and
      `https://example.com/2024/11/a-post-slug-here` is a long way to say
      nothing.

  Deliberately not an `:error` for the latter two: both are judgement calls
  with real exceptions ("read more" under a card heading that supplies the
  context is genuinely fine), and an advisory that cries wolf on a defensible
  choice is one authors learn to dismiss.

  ## Reachability, honestly (#823)

  This reads `Kiln.Advisory.Body`'s `links`, which come from Portable Text
  `markDefs`. Today those survive the API, MCP and import write paths but
  **not** the content editor: TipTap is built without a Link extension, so
  opening a page parses its anchors away and the autosave persists the loss.
  Until #823 lands, this check sees links on content that hasn't been opened
  in the editor and nothing on content that has.

  That is a bug in the editor, not a reason to hold this back — the check is
  correct, and it starts reporting the day links can exist. But it is worth
  knowing before concluding from a quiet panel that a page has no bad links.

  ## Why the phrase list is short

  Only phrases that are uninformative *whatever* the surrounding text says.
  "Learn more about invoicing" is a good link; "learn more" is not — so the
  match is on the WHOLE text, never a substring. A substring match would flag
  every one of the good ones.
  """
  use Kiln.Advisory

  alias Kiln.Advisory.Context

  # Matched against the entire (folded) link text, never as a substring — see
  # the moduledoc. Kept to phrases that carry no information at all rather than
  # growing into a style guide.
  # An explicit list, NOT `~w(...)`: that sigil splits on whitespace, which
  # silently turns every multi-word phrase here into its individual words —
  # so "click here" would never match while "click" and "here" each would.
  @uninformative [
    "here",
    "click",
    "link",
    "this",
    "more",
    "click here",
    "clickhere",
    "click this",
    "click this link",
    "go here",
    "read more",
    "read this",
    "learn more",
    "find out more",
    "see more",
    "more info",
    "more information",
    "details",
    "this link",
    "this page",
    "download",
    "continue",
    "continue reading"
  ]

  # Comfortably past the longest phrase above (`"continue reading"`, 17), with
  # room for a rewrite. See `uninformative?/1` for why this is a guard rather
  # than a nicety.
  @max_phrase_length 40

  # A label that is itself a URL: a scheme, a `www.` host, a same-origin path,
  # or a dotted host WITH a path.
  #
  # The last clause requires the path on purpose. Matching a bare dotted token
  # meant flagging `Node.js`, `asp.net`, `Ph.D` and `annual-report.pdf` — all
  # perfectly good link text, and all common in exactly the technical writing
  # this would otherwise nag hardest. A bare `example.com` label now goes
  # unreported, which is the cheaper mistake: a false positive on a correct
  # link is what teaches an author to ignore the panel.
  @bare_url ~r{\A(?:[a-z][a-z0-9+.-]*://\S+|www\.\S+|/\S*|[\w-]+(?:\.[\w-]+)+/\S*)\z}i

  @impl Kiln.Advisory
  def check(%Context{body: %{links: []}}), do: :n_a

  def check(%Context{body: %{links: links}}) do
    [
      report(links, :link_text_empty, :error, &empty?/1),
      report(links, :link_text_uninformative, :warning, &uninformative?/1),
      report(links, :link_text_bare_url, :warning, &bare_url?/1)
    ]
  end

  defp report(links, code, severity, predicate) do
    case Enum.filter(links, &predicate.(&1.text)) do
      [] ->
        :ok

      matched ->
        finding(severity, code, :body, %{
          count: length(matched),
          # The first is enough to name: the panel shows one example and a
          # count, since listing every "click here" on a long page fills the
          # sidebar with the same string.
          #
          # Truncated because link text is unbounded author input and this
          # string is interpolated into a sidebar sentence — a multi-megabyte
          # label would otherwise be pushed down the socket on every render.
          example: truncate(hd(matched).text),
          indexes: matched |> Enum.map(& &1.index) |> Enum.uniq()
        })
    end
  end

  defp empty?(text), do: String.trim(text) == ""

  # The length guard runs BEFORE the fold, and is load-bearing rather than an
  # optimization. `fold/1`'s trailing-punctuation strip is a global
  # `String.replace` with a `\z`-anchored pattern, which PCRE retries from
  # every offset — quadratic in the length of the run. A 32 KB link label of
  # punctuation took 4.6 seconds to fold, and this check runs on every
  # keystroke *and* on opening a document, so one such label planted through
  # the API would wedge the editor for whoever opened that page.
  #
  # Nothing in `@uninformative` is longer than `@max_phrase_length`, so
  # anything past it cannot match anyway: the guard is exactly as correct as
  # folding first, and it keeps a pathological label out of the regex
  # entirely.
  defp uninformative?(text) do
    String.length(text) <= @max_phrase_length and fold(text) in @uninformative
  end

  defp bare_url?(text) do
    trimmed = String.trim(text)
    trimmed != "" and Regex.match?(@bare_url, trimmed)
  end

  @max_example_length 60

  # Graphemes, not bytes: slicing by byte count can split a multi-byte
  # character, and `byte_size/1` would let a 60-character CJK example through
  # at ~180 bytes.
  defp truncate(text) do
    if String.length(text) <= @max_example_length,
      do: text,
      else: String.slice(text, 0, @max_example_length - 1) <> "…"
  end

  # Trailing punctuation is dropped so "Click here!" and "click here" are the
  # same phrase; interior punctuation is left alone. Only ever reached with a
  # short string — see `uninformative?/1`.
  defp fold(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]+\z/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
