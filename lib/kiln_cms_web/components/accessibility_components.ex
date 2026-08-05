defmodule KilnCMSWeb.AccessibilityComponents do
  @moduledoc """
  The accessibility half of the editor's advisory panel (#495).

  The counterpart of `KilnCMSWeb.SeoComponents`, and deliberately the same
  shape: rendering is shared (`KilnCMSWeb.AdvisoryComponents` owns the severity
  vocabulary, icons, jump links and grade pill), so all that lives here is the
  translation of a finding code into prose.

  ## Why the same code can read differently here

  Several checks report into both panels — a skipped heading level, an image
  with no alt text. The *finding* is the same; the sentence an author needs is
  not always. `:no_headings` in the SEO panel is about scannability; here it is
  about the outline a screen-reader user navigates by, which is a different
  reason to care and often a more persuasive one.

  So this module states its own sentence wherever the framing genuinely
  differs, and falls through to `SeoComponents.finding_message/2` for the rest
  rather than restating two dozen clauses that would then drift.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.AdvisoryComponents, only: [advisory_findings: 1, advisory_grade: 1]

  @doc "Traffic-light summary for the accessibility panel's heading row."
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def a11y_grade_badge(assigns) do
    ~H"""
    <.advisory_grade report={@report} class={@class} />
    """
  end

  @doc "The accessibility findings checklist."
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def a11y_findings(assigns) do
    ~H"""
    <%!-- `message_fn` is arity 1; the SEO panel closes over its pinned-slug
          flag the same way. Nothing here needs one, so it's fixed false. --%>
    <.advisory_findings
      findings={@report.findings}
      message_fn={&finding_message(&1, false)}
      class={@class}
    />
    """
  end

  @doc """
  The sentence for one finding code, in the accessibility framing.

  The second argument is the shared `message_fn` contract's "pinned slug" flag,
  which nothing here needs — it exists so this can be passed where
  `SeoComponents.finding_message/2` is. No default: an arity-1 head would be
  dead surface, since every caller supplies it.
  """
  def finding_message(finding, pinned?)

  # ── Headings ──────────────────────────────────────────────────────────────

  # Framed by consequence, not by rule. "Don't skip levels" is a style
  # instruction an author can reasonably disagree with; "this is how someone
  # navigates your page" is a fact about a reader.
  def finding_message(%{code: :heading_levels_skipped, args: a}, _pinned?),
    do:
      gettext(
        "Heading levels jump from H%{from} to H%{to} — screen-reader users navigate by this outline, and a gap reads as a missing section.",
        from: a.from,
        to: a.to
      )

  def finding_message(%{code: :no_headings}, _pinned?),
    do:
      gettext(
        "No headings — there's no outline to navigate by, so the page can only be read start to finish."
      )

  def finding_message(%{code: :headings_empty, args: a}, _pinned?) do
    ngettext(
      "1 heading has no text — it structures the page while saying nothing.",
      "%{count} headings have no text — they structure the page while saying nothing.",
      a.count,
      count: a.count
    )
  end

  # ── Links ─────────────────────────────────────────────────────────────────

  def finding_message(%{code: :link_text_empty, args: a}, _pinned?) do
    ngettext(
      "1 link has no text — there's nothing to click and nothing to announce.",
      "%{count} links have no text — there's nothing to click and nothing to announce.",
      a.count,
      count: a.count
    )
  end

  # The example is quoted because the fix is to rewrite that exact phrase, and
  # naming it saves the author hunting for which link is meant.
  def finding_message(%{code: :link_text_uninformative, args: a}, _pinned?) do
    ngettext(
      "Link text “%{example}” doesn't say where it goes — screen readers can list links out of context.",
      "%{count} links have text like “%{example}” that doesn't say where they go — screen readers can list links out of context.",
      a.count,
      count: a.count,
      example: a.example
    )
  end

  def finding_message(%{code: :link_text_bare_url, args: a}, _pinned?) do
    ngettext(
      "A link is labelled with its own URL — some screen readers read that out character by character.",
      "%{count} links are labelled with their own URL — some screen readers read those out character by character.",
      a.count,
      count: a.count
    )
  end

  # ── Text ──────────────────────────────────────────────────────────────────

  def finding_message(%{code: :all_caps_run, args: a}, _pinned?),
    do:
      gettext(
        "Text set in capitals (“%{example}”) — some screen readers spell it out letter by letter, and capitals are harder to read. Use styling instead.",
        example: a.example
      )

  # ── Everything else ───────────────────────────────────────────────────────

  # Shared codes whose SEO sentence already says the accessibility thing —
  # `images_missing_alt` leads with "screen readers can't describe it" — plus
  # any code a plugin adds. Delegating beats restating: a second copy of a
  # sentence is a second copy to translate and to keep true.
  def finding_message(finding, pinned?),
    do: KilnCMSWeb.SeoComponents.finding_message(finding, pinned?)
end
