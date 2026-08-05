defmodule KilnCMSWeb.SeoComponents do
  @moduledoc """
  The SEO half of the editor's advisory panel: the sentences for each SEO
  finding code, plus thin wrappers over `KilnCMSWeb.AdvisoryComponents`.

  Rendering itself is shared — severity vocabulary, icons, jump links, the
  grade pill — so an accessibility panel (#495) reuses it by supplying its own
  message table rather than copying this module. All that lives here is the
  translation of a code into prose, which is exactly the part that differs.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.AdvisoryComponents, only: [advisory_findings: 1, advisory_grade: 1]

  @doc "Traffic-light summary for the SEO panel's heading row."
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def seo_grade_badge(assigns) do
    ~H"""
    <.advisory_grade report={@report} class={@class} />
    """
  end

  @doc """
  The SEO findings checklist.

  `slug_customized?` only affects the keyphrase-in-slug advice: a pinned slug
  won't re-derive on its own, so the author is told how to unpin it.
  """
  attr :report, :map, required: true
  attr :slug_customized?, :boolean, default: false
  attr :class, :any, default: nil

  def seo_findings(assigns) do
    assigns = assign(assigns, :message_fn, &finding_message(&1, assigns.slug_customized?))

    ~H"""
    <.advisory_findings findings={@report.findings} message_fn={@message_fn} class={@class} />
    """
  end

  @doc """
  A single finding's translated message.

  `slug_customized?` only affects the keyphrase-in-slug advice: a pinned slug
  won't re-derive on its own, so the author is told how to unpin it.
  """
  @spec finding_message(map(), boolean()) :: String.t()
  def finding_message(finding, slug_customized? \\ false)

  # ── SEO title ─────────────────────────────────────────────────────────────

  def finding_message(%{code: :seo_title_missing}, _pinned?),
    do: gettext("No SEO title — the page title will be used instead.")

  # Phrased to read correctly at any count — a 1-character title would make
  # "is 1 characters" out of a naive interpolation.
  def finding_message(%{code: :seo_title_short, args: a}, _pinned?),
    do:
      gettext(
        "SEO title is short — %{length} of the %{min}–%{max} characters search results show.",
        length: a.length,
        min: a.min,
        max: a.max
      )

  def finding_message(%{code: :seo_title_long, args: a}, _pinned?),
    do:
      gettext("SEO title is %{length} characters — search results truncate past %{max}.",
        length: a.length,
        max: a.max
      )

  def finding_message(%{code: :seo_title_duplicates_title}, _pinned?),
    do:
      gettext("The SEO title just repeats the page title — a distinct one usually reads better.")

  # ── SEO description ───────────────────────────────────────────────────────

  def finding_message(%{code: :seo_description_missing}, _pinned?),
    do: gettext("No SEO description — search engines will invent one from the page text.")

  def finding_message(%{code: :seo_description_short, args: a}, _pinned?),
    do:
      gettext(
        "SEO description is short — %{length} of the %{min}–%{max} characters search results show.",
        length: a.length,
        min: a.min,
        max: a.max
      )

  def finding_message(%{code: :seo_description_long, args: a}, _pinned?),
    do:
      gettext("SEO description is %{length} characters — search results truncate past %{max}.",
        length: a.length,
        max: a.max
      )

  # ── Keyphrase ─────────────────────────────────────────────────────────────

  def finding_message(%{code: :keyphrase_missing}, _pinned?),
    do: gettext("No focus keyphrase set — the first SEO keyword becomes the focus keyphrase.")

  def finding_message(%{code: :keyphrase_not_in_title}, _pinned?),
    do: gettext("The focus keyphrase doesn't appear in the title or SEO title.")

  # A pinned slug won't re-derive on its own, so tell the author how.
  def finding_message(%{code: :keyphrase_not_in_slug}, true),
    do:
      gettext(
        "The slug doesn't contain the focus keyphrase — clear the slug field to re-derive it."
      )

  def finding_message(%{code: :keyphrase_not_in_slug}, false),
    do: gettext("The slug doesn't contain the focus keyphrase.")

  def finding_message(%{code: :keyphrase_not_in_description}, _pinned?),
    do: gettext("The focus keyphrase doesn't appear in the SEO description.")

  def finding_message(%{code: :keyphrase_not_in_first_paragraph}, _pinned?),
    do: gettext("The focus keyphrase doesn't appear in the opening paragraph.")

  def finding_message(%{code: :keyphrase_density_low, args: a}, _pinned?),
    do:
      gettext("Focus keyphrase density is %{density}% — below the %{min}% guideline.",
        density: a.density,
        min: a.min
      )

  def finding_message(%{code: :keyphrase_density_high, args: a}, _pinned?),
    do:
      gettext(
        "Focus keyphrase density is %{density}% — above %{max}% reads as keyword stuffing.",
        density: a.density,
        max: a.max
      )

  # ── Slug ──────────────────────────────────────────────────────────────────

  def finding_message(%{code: :slug_long}, _pinned?),
    do: gettext("Long slug — search engines and shared links favor short URLs (≤ 6 words).")

  # ── Structure ─────────────────────────────────────────────────────────────

  def finding_message(%{code: :thin_content, args: a}, _pinned?),
    do:
      gettext("Only %{count} words — pages under %{min} rarely rank well.",
        count: a.count,
        min: a.min
      )

  def finding_message(%{code: :no_headings}, _pinned?),
    do: gettext("No headings — long pages are easier to scan when broken into sections.")

  def finding_message(%{code: :heading_levels_skipped, args: a}, _pinned?),
    do:
      gettext("Heading levels jump from H%{from} to H%{to} — don't skip levels.",
        from: a.from,
        to: a.to
      )

  # ── Images ────────────────────────────────────────────────────────────────

  def finding_message(%{code: :images_missing_alt, args: a}, _pinned?) do
    ngettext(
      "1 image has no alt text — screen readers can't describe it.",
      "%{count} images have no alt text — screen readers can't describe them.",
      a.count,
      count: a.count
    )
  end

  # ── Internal links (#474) ─────────────────────────────────────────────────

  # The paths are named rather than counted. "3 broken links" turns advice into
  # a search task, and the author is the one person who knows which of them was
  # a typo.
  def finding_message(%{code: :internal_links_missing, args: a}, _pinned?) do
    ngettext(
      "%{paths} doesn't resolve — readers clicking it get a 404.",
      "%{count} links don't resolve — readers clicking them get a 404: %{paths}",
      a.count,
      count: a.count,
      paths: Enum.join(a.paths, ", ")
    )
  end

  def finding_message(%{code: :internal_links_unpublished, args: a}, _pinned?) do
    ngettext(
      "%{paths} points at content that isn't published yet.",
      "%{count} links point at content that isn't published yet: %{paths}",
      a.count,
      count: a.count,
      paths: Enum.join(a.paths, ", ")
    )
  end

  def finding_message(%{code: :og_image_missing}, _pinned?),
    do: gettext("No social image — links to this page will share without a preview picture.")

  # ── Links, as an SEO concern (#495) ───────────────────────────────────────

  # `Kiln.Advisory.Checks.LinkText` reports into BOTH panels, so these need a
  # sentence here too — without one they fall to the catch-all at the bottom
  # and render as the bare atom name. Framed for search rather than for a
  # screen reader (`KilnCMSWeb.AccessibilityComponents` has that version):
  # anchor text is a ranking signal, which is a different reason to care about
  # the same defect.
  def finding_message(%{code: :link_text_uninformative, args: a}, _pinned?) do
    ngettext(
      "Link text “%{example}” describes nothing — anchor text tells search engines what a page is about.",
      "%{count} links have text like “%{example}” that describes nothing — anchor text tells search engines what a page is about.",
      a.count,
      count: a.count,
      example: a.example
    )
  end

  def finding_message(%{code: :link_text_empty, args: a}, _pinned?) do
    ngettext(
      "1 link has no text at all — there is no anchor text to read.",
      "%{count} links have no text at all — there is no anchor text to read.",
      a.count,
      count: a.count
    )
  end

  def finding_message(%{code: :link_text_bare_url, args: a}, _pinned?) do
    ngettext(
      "A link is labelled with its own URL — a descriptive phrase carries more signal.",
      "%{count} links are labelled with their own URL — a descriptive phrase carries more signal.",
      a.count,
      count: a.count
    )
  end

  def finding_message(%{code: :headings_empty, args: a}, _pinned?) do
    ngettext(
      "1 heading is empty — it adds a level to the outline without a topic.",
      "%{count} headings are empty — they add levels to the outline without a topic.",
      a.count,
      count: a.count
    )
  end

  # ── Readability ───────────────────────────────────────────────────────────

  def finding_message(%{code: :long_sentences, args: a}, _pinned?),
    do:
      gettext("%{percent}% of sentences run over %{max} words — try breaking some up.",
        percent: a.percent,
        max: a.max
      )

  def finding_message(%{code: :long_paragraphs, args: a}, _pinned?) do
    ngettext(
      "1 paragraph runs over %{max} words — consider splitting it.",
      "%{count} paragraphs run over %{max} words — consider splitting them.",
      a.count,
      count: a.count,
      max: a.max
    )
  end

  def finding_message(%{code: :hard_to_read, args: a}, _pinned?),
    do:
      gettext("Reading ease is %{score}/100 — shorter words and sentences would help.",
        score: a.score
      )

  # An unknown code (a future check, or a plugin's) must never crash the editor.
  def finding_message(%{code: code}, _pinned?), do: to_string(code)
end
