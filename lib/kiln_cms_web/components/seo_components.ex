defmodule KilnCMSWeb.SeoComponents do
  @moduledoc """
  The editor-facing half of SEO analysis (#476): a traffic-light badge and a
  non-blocking findings checklist.

  `KilnCMS.Seo.Analyzer` deliberately emits codes and interpolation args rather
  than sentences, so it stays free of any web or Gettext dependency. This module
  is where those codes become translated prose, via `finding_message/2` — the
  same split `KilnCMS.Slug.Lint` and the editor's old `lint_message/2` already
  used.

  Nothing here ever blocks a save. Findings are advice.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [icon: 1]

  @doc """
  Traffic-light summary for the SEO panel's `<summary>` row: a coloured grade
  pill plus an "n of m checks passing" counter.
  """
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def seo_grade_badge(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]}>
      <span class={[
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        grade_tone(@report.grade)
      ]}>
        {grade_label(@report.grade)}
      </span>
      <span :if={@report.total > 0} class="text-xs font-normal text-base-content/60">
        {gettext("%{passed}/%{total}", passed: @report.passed, total: @report.total)}
      </span>
    </span>
    """
  end

  @doc """
  The findings checklist. Renders nothing when the document is clean, so a
  well-formed page shows no noise at all.
  """
  attr :report, :map, required: true
  attr :slug_customized?, :boolean, default: false
  attr :class, :any, default: nil

  def seo_findings(assigns) do
    ~H"""
    <ul :if={@report.findings != []} class={["space-y-1", @class]}>
      <li
        :for={finding <- @report.findings}
        class={["flex items-start gap-1.5 text-xs", severity_tone(finding.severity)]}
      >
        <.icon name={severity_icon(finding.severity)} class="mt-0.5 size-3.5 shrink-0" />
        <span>{finding_message(finding, @slug_customized?)}</span>
      </li>
    </ul>
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
      gettext("Focus keyphrase density is %{density}%% — below the %{min}%% guideline.",
        density: a.density,
        min: a.min
      )

  def finding_message(%{code: :keyphrase_density_high, args: a}, _pinned?),
    do:
      gettext(
        "Focus keyphrase density is %{density}%% — above %{max}%% reads as keyword stuffing.",
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

  def finding_message(%{code: :og_image_missing}, _pinned?),
    do: gettext("No social image — links to this page will share without a preview picture.")

  # ── Readability ───────────────────────────────────────────────────────────

  def finding_message(%{code: :long_sentences, args: a}, _pinned?),
    do:
      gettext("%{percent}%% of sentences run over %{max} words — try breaking some up.",
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

  # ── Presentation helpers ──────────────────────────────────────────────────

  defp grade_label(:good), do: gettext("Good")
  defp grade_label(:ok), do: gettext("Needs work")
  defp grade_label(:poor), do: gettext("Poor")

  defp grade_tone(:good), do: "bg-success/15 text-success"
  defp grade_tone(:ok), do: "bg-warning/20 text-warning-content"
  defp grade_tone(:poor), do: "bg-error/12 text-error"

  defp severity_tone(:error), do: "text-error"
  defp severity_tone(:warning), do: "text-warning"
  defp severity_tone(:info), do: "text-base-content/60"

  defp severity_icon(:error), do: "hero-exclamation-triangle"
  defp severity_icon(:warning), do: "hero-light-bulb"
  defp severity_icon(:info), do: "hero-information-circle"
end
