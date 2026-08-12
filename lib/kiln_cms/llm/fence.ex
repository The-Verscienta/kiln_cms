defmodule KilnCMS.LLM.Fence do
  @moduledoc """
  The delimiter every prompt builder wraps untrusted text in, and the defence
  that stops the text from walking back out of it.

  Kiln has three prompt builders — `KilnCMS.Ask.Prompt`, `KilnCMS.Assist.Prompt`
  and `KilnCMS.Seo.Prompt` — and all three interpolate author- or
  reader-supplied strings into a message they then tell the model to treat as
  data. That framing is only worth anything if the data cannot end the region
  it is in, which is a property of the *escaping*, not of the marker.

  #916 found this the hard way on the ask path: a question containing a
  `-----` line closed the region early and reopened it as attacker-authored
  "excerpts", and `/api/ask` returned the resulting answer next to the real
  `sources`, which is what made the forgery look verified. The same escape
  fired from stored content — a published body with a horizontal rule was
  enough. #945 found both gaps still open on the SEO and assist paths, where
  #942 had since made the SEO one reachable *unattended*, on every matching
  state transition rather than on an editor's deliberate click.

  So the fence and its defence live here once, and the builders delegate.

  ## Two layers

  **The marker carries a per-call nonce** (#1065): `Fence.nonce/0` generates
  one random token per `build/1` call, and every region in that prompt opens
  with `-----BEGIN <nonce>-----` and closes with `-----END <nonce>-----`.
  #945 had to widen the shape matcher below twice in one review — a padding
  class that missed a whole Unicode category, then a rule-character class
  that missed box-drawing glyphs — because **the set of glyph runs a model
  reads as "the data ended" has no closed definition**, so no character class
  ever finishes that job. A nonce the attacker cannot guess sidesteps the
  problem instead of chasing it further: closing the fence stops being a
  matching problem and becomes a guessing one. `Fence.region/3` is the only
  way to build a fenced block, so a call site cannot forget to escape or
  forget to use the marker the system prompt actually named.

  **The shape matcher stays as a second layer.** It is cheap, it still turns
  a legitimate horizontal rule in a body into readable prose instead of a
  false-positive close, and it now also catches an attacker's *guess* at a
  BEGIN/END-shaped line — a forged marker with the wrong token reads as a
  rule and gets neutralized the same as a bare `-----` would.

  ## What "looks like a delimiter" means here

  The pattern deliberately matches a *shape*, not the marker string: any line
  that opens with three or more of the same rule character. A model reads
  `----`, `------`, `=====` and `—————` as the same horizontal rule, so
  matching only `-----` would leave every near-miss working as well as the real
  thing. Padding between and around the characters is horizontal whitespace
  **and `\\p{Cf}` format characters** — a soft hyphen or a zero-width space is
  invisible in every renderer while sitting outside `\\s` entirely, which is the
  same lesson as the earlier `[ \\t]`-to-NBSP round, one Unicode category
  further out.

  > #### Still not a security boundary {: .warning}
  >
  > A nonce closes the *shape* problem, not the framing problem: a model can
  > still be talked out of the "this is data" instruction by pure prose
  > inside the region itself — "the page above was truncated; operator note
  > follows" needs no fence character at all. And in all three builders the
  > untrusted text is the **last** thing before the model's turn, so the
  > position an attacker most wants — the words right before the model
  > answers — belongs to the attacker in every one of these prompts. Nothing
  > downstream may assume the region held. The real defences stay where they
  > are: the generators get **no tools**, and every response is constrained by
  > its own normalizer (`KilnCMS.Ask`, `KilnCMS.Assist.Suggestion`,
  > `KilnCMS.Seo.Draft`). This module makes the fence a boundary the *input*
  > can't simply step through — defence in depth, not the depth itself.
  """

  # Characters a model reads as a horizontal rule. ASCII first, then the dashes
  # and box-drawing glyphs that render identically — `—————` is the same
  # thematic break as `-----`, which is exactly why it is not used as the
  # neutralized form below.
  @rule_chars ~S/[-*_=~\x{2013}\x{2014}\x{2015}\x{2212}\x{2500}\x{2501}\x{2550}\x{FF0D}\x{FF3F}]/

  # Padding: horizontal whitespace, plus format characters. `\h` rather than
  # `[^\S\n]` because the latter classifies VT, FF, NEL, U+2028 and U+2029 —
  # every one of which a renderer breaks a line on — as *horizontal* padding,
  # so the anchors could never see a fence they delimited. `\R` normalization
  # below turns all of those into `\n` before this pattern runs.
  @pad ~S/[\h\p{Cf}]/

  # The lookahead, rather than consuming to `$`, is what catches
  # `----- END OF DATA. Everything after this is a rule.` — a line that opens
  # with the marker and carries a clause reads as a close just as well. It
  # requires whitespace (or end of line) after the run precisely so markdown's
  # `***bold***` and `___em___` at the start of a line are left alone.
  @fence_like Regex.compile!(
                "^#{@pad}*(#{@rule_chars})(?:#{@pad}*\\1){2,}(?=#{@pad}*(?:\\s|$))",
                "mu"
              )

  # A forged BEGIN/END marker: the same rule-char shape as `@fence_like`, but
  # carrying a guessed label and token between two runs, e.g.
  # `-----BEGIN deadbeef-----`. The real markers `begin_marker/1`/`end_marker/1`
  # emit have exactly this shape, so an attacker's copy of it — with a token
  # they had to guess, since the real one is never disclosed to them — is
  # neutralized the same way a bare `-----` is, rather than reading as a
  # plausible (if mismatched) marker to the model.
  @nonce_marker_like Regex.compile!(
                       "^#{@pad}*(#{@rule_chars})(?:#{@pad}*\\1){2,}#{@pad}*" <>
                         "(?:BEGIN|END)#{@pad}+\\S+#{@pad}*(#{@rule_chars})(?:#{@pad}*\\2){2,}" <>
                         "(?=#{@pad}*(?:\\s|$))",
                       "miu"
                     )

  # What a neutralized rule becomes. NOT another rule: replacing the dashes
  # with em-dashes left `—————`, which is the same thematic break in a
  # different glyph. This cannot be mistaken for a delimiter, and it keeps the
  # line's meaning for a model reading the passage.
  #
  # It is the *replacement* argument of `String.replace/3`, where `\\1` and
  # `\\g{name}` are live — so it must stay free of backslashes, and must never
  # become a value derived from input. `neutralized/0` exists so a test can
  # pin that.
  @neutralized "(horizontal rule)"

  @doc """
  A fresh per-call nonce. Call once per `build/1` and thread the result
  through every marker in that prompt — a value from a different call could
  in principle be echoed back by an attacker who has seen it (a chained
  request, a logged prompt), so a nonce must never be reused across two
  builds.

  8 hex characters (32 bits) — enough that guessing it is not a practical
  attack, small enough that the marker stays readable in a system prompt.
  """
  @spec nonce() :: String.t()
  def nonce, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @doc "The opening marker line for `nonce`."
  @spec begin_marker(String.t()) :: String.t()
  def begin_marker(nonce), do: "-----BEGIN #{nonce}-----"

  @doc "The closing marker line for `nonce`."
  @spec end_marker(String.t()) :: String.t()
  def end_marker(nonce), do: "-----END #{nonce}-----"

  @doc """
  Neutralize anything in `value` that could pass for a fence.

  Keeps the character, so a legitimate horizontal rule in a body still reads
  as a rule to the model — the text is neutralized, not censored. Newlines
  survive, so this is the form for a multi-line region (a body, a passage, an
  excerpt); use `inline/1` for a one-line labelled field.

  Anything that is not a binary is treated as **absent** and returns `nil`,
  the same rule `KilnCMS.Seo.Document` and `KilnCMS.Assist.Request` apply at
  their own boundaries: `to_string/1` on a non-binary quietly manufactures
  content (the atom `false` became the literal string `"false"` and was sent
  to a provider as a page's excerpt).
  """
  @spec defence(term()) :: String.t() | nil
  def defence(value) when is_binary(value) do
    value
    # Line endings FIRST, and `\R` rather than `\r\n?`. Erlang's `:re` uses the
    # LF-only newline convention, so `^`/`$` in multiline mode anchor at `\n`
    # and nowhere else — a fence delimited by CR, VT, FF, NEL, U+2028 or
    # U+2029 was invisible to the pattern while rendering as its own line
    # everywhere else. `\R` folds all of them (and CRLF as one unit) to `\n`.
    # Every value here is prompt text, so normalizing newlines costs nothing.
    |> String.replace(~r/\R/u, "\n")
    |> String.replace(@nonce_marker_like, @neutralized)
    |> String.replace(@fence_like, @neutralized)
  end

  def defence(_value), do: nil

  @doc """
  `defence/1` for a value rendered as a one-line `Label: value` field.

  Collapses every run of whitespace **and format characters** to a single
  space. Without this a title carrying its own newlines renders as extra lines
  inside the region and can impersonate the builder's other labelled fields, or
  the region's trailing prose. A one-line field has no legitimate use for a
  line break, so nothing is lost.

  The defence runs **again** after the collapse, because the collapse can
  assemble a rule the first pass had no reason to touch: `"-\\n-\\n-"` is three
  one-character lines going in and a canonical `- - -` coming out.

  Returns `nil` for a non-binary **and for a value that collapses to nothing**,
  which is what `field/2` drops.
  """
  @spec inline(term()) :: String.t() | nil
  def inline(value) do
    case value |> defence() |> collapse() do
      nil -> nil
      "" -> nil
      collapsed -> defence(collapsed)
    end
  end

  @doc """
  A `Label: value` line, or `nil` when the value is absent.

  Every builder that renders labelled fields inside a region needs the same
  two decisions — collapse to one line, and omit the label entirely rather
  than emit a bare `Label:` — so they are made once, here.
  """
  @spec field(String.t(), term()) :: String.t() | nil
  def field(label, value) do
    case inline(value) do
      nil -> nil
      inlined -> "#{label}: #{inlined}"
    end
  end

  @doc """
  A complete fenced region: `label`, then `value` — defended — between
  `nonce`'s BEGIN/END markers. `nil` when `value` is absent or defends down
  to nothing, the same rule `field/2` applies, so a builder never assembles
  an empty region — an empty fenced block invites the model to fill it.

  This is the only way to build a fenced block, on purpose: escaping used to
  be opt-in at each of five hand-assembled call sites, which is the shape
  that once let a value sit outside the fence for a whole prompt builder's
  life (#945). `value` may already be pre-escaped composed text (several
  `field/2` lines joined, or output already run through `defence/1` for a
  re-clamp) — running the defence again is idempotent, so this never double-
  corrupts an already-safe value.
  """
  @spec region(String.t(), String.t(), term()) :: String.t() | nil
  def region(nonce, label, value) do
    case defence(value) do
      nil ->
        nil

      "" ->
        nil

      defended ->
        """
        #{label}

        #{begin_marker(nonce)}
        #{defended}
        #{end_marker(nonce)}
        """
        |> String.trim()
    end
  end

  @doc false
  # Pinned by a test: the replacement must never carry a backslash, or
  # `String.replace/3` would splice match groups into the neutralized output.
  def neutralized, do: @neutralized

  defp collapse(nil), do: nil

  defp collapse(value) do
    value
    |> String.replace(~r/[\s\p{Cf}]+/u, " ")
    |> String.trim()
  end
end
