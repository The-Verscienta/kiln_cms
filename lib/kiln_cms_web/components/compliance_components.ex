defmodule KilnCMSWeb.ComplianceComponents do
  @moduledoc """
  The compliance half of the editor's advisory panel (#377).

  The third sibling of `KilnCMSWeb.SeoComponents` and
  `KilnCMSWeb.AccessibilityComponents`, and the same shape: rendering is shared
  (`KilnCMSWeb.AdvisoryComponents` owns severity tone, icons and the grade
  pill), so all that lives here is the translation of a finding code into
  prose.

  ## The sentences quote the phrase, always

  A claim finding is useless without the words that triggered it. "This page
  makes a regulatory claim" sends an author to re-read their own article
  hunting for what the tool objected to; "'clinically proven' is a claim about
  a fact of record" is actionable in one glance.

  So every message here interpolates `args.phrases`, and the phrasing is
  written to be *dismissable*. These are heuristics over a phrase list — a
  match is a prompt to look, not a verdict — and copy that asserts wrongdoing
  is copy an author learns to resent and then ignore.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.AdvisoryComponents, only: [advisory_findings: 1, advisory_grade: 1]

  @doc "Traffic-light summary for the compliance panel's heading row."
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def compliance_grade_badge(assigns) do
    ~H"""
    <.advisory_grade report={@report} class={@class} />
    """
  end

  @doc "The compliance findings checklist."
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def compliance_findings(assigns) do
    ~H"""
    <.advisory_findings
      findings={@report.findings}
      message_fn={&finding_message(&1, false)}
      class={@class}
    />
    """
  end

  @doc """
  The sentence for one finding code.

  The second argument is the shared `message_fn` contract's "pinned slug" flag,
  which nothing here needs — it exists so this can be passed where
  `KilnCMSWeb.SeoComponents.finding_message/2` is.
  """
  def finding_message(finding, pinned?)

  def finding_message(%{code: :regulatory_claim, args: a}, _pinned?),
    do:
      gettext(
        "%{phrases} asserts an approval or endorsement. Cite the specific finding, or reword it.",
        phrases: quoted(a)
      )

  def finding_message(%{code: :safety_claim, args: a}, _pinned?),
    do:
      gettext(
        "%{phrases} promises safety without qualification — there is no way for a reader to be the exception.",
        phrases: quoted(a)
      )

  def finding_message(%{code: :efficacy_claim, args: a}, _pinned?),
    do:
      gettext(
        "%{phrases} guarantees a result. Soften it, or say who it worked for and how that was measured.",
        phrases: quoted(a)
      )

  def finding_message(%{code: :medical_advice_claim, args: a}, _pinned?),
    do:
      gettext(
        "%{phrases} positions this as a substitute for seeing a clinician.",
        phrases: quoted(a)
      )

  def finding_message(%{code: :disclaimer_missing, args: a}, _pinned?),
    do:
      gettext(
        "The required disclaimer is missing. Add it verbatim: “%{disclaimer}”",
        disclaimer: a.disclaimer
      )

  # A rule an operator added has a code this module has never heard of, and
  # inventing a sentence for it is impossible — so the fallback quotes the
  # phrases and names the rule. That reads as a real advisory rather than a
  # blank, which is what a missing clause would render as.
  def finding_message(%{args: %{phrases: _phrases} = a} = finding, _pinned?),
    do:
      gettext("%{phrases} matches the %{rule} compliance rule.",
        phrases: quoted(a),
        rule: humanize(finding.code)
      )

  def finding_message(finding, pinned?),
    do: KilnCMSWeb.SeoComponents.finding_message(finding, pinned?)

  # Curly quotes and a comma-joined list, so a finding naming three phrases
  # reads as prose rather than as an inspected list.
  defp quoted(%{phrases: phrases}) when is_list(phrases) and phrases != [],
    do: Enum.map_join(phrases, ", ", &"“#{&1}”")

  defp quoted(_args), do: gettext("A flagged phrase")

  defp humanize(code) do
    code
    |> Atom.to_string()
    |> String.replace("_", " ")
  end
end
