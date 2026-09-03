defmodule KilnCMSWeb.AdvisoryComponents do
  @moduledoc """
  Rendering for `Kiln.Advisory` findings — the grade pill and the severity-tiered
  list the content editor shows.

  Feature-neutral by construction. Checks emit codes and interpolation args, so
  the only thing that varies between an SEO panel and an accessibility panel is
  which function turns a code into a sentence — passed in as `message_fn`.
  Everything else (severity vocabulary, icons, jump links to the offending
  block, the "n of m passing" counter) is shared, which is the point: #495
  asked for one advisory surface rather than two that drift.

  Nothing here ever blocks a save. Findings are advice.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [icon: 1]

  alias Kiln.Advisory.Finding

  # A gallery with fifty un-alt'd images shouldn't render fifty links into a
  # sidebar panel.
  @max_jump_links 5

  @doc """
  Traffic-light summary: a coloured grade pill plus an "n of m checks passing"
  counter.
  """
  attr :report, :map, required: true
  attr :class, :any, default: nil

  def advisory_grade(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]}>
      <span class={[
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        grade_tone(@report.grade)
      ]}>
        {grade_label(@report.grade)}
      </span>
      <span
        :if={@report.total > 0}
        class="text-xs font-normal text-base-content/60"
        aria-label={
          gettext("%{passed} of %{total} checks passing",
            passed: @report.passed,
            total: @report.total
          )
        }
      >
        {@report.passed}/{@report.total}
      </span>
    </span>
    """
  end

  # Every index a finding names rides along in `data-jump-blocks`, so the
  # client can highlight all fifty un-alt'd images at once even though only
  # five get a link. Capped all the same, so the attribute can't grow without
  # bound on a pathological document.
  @max_marked_blocks 50

  @doc """
  The findings list. Renders nothing when there are none, so a clean document
  shows no noise at all.

  `message_fn` turns a `Kiln.Advisory.Finding` into a translated sentence.

  ## Click to locate

  Each row is a button. Clicking it scrolls the editor to whatever the finding
  is about and highlights it — the alt-text input of the image with none, the
  "click here" link inside a rich-text block, the SEO description field — via
  the delegated handler in `assets/js/advisory_jump.js`. The row carries what
  that handler needs as `data-jump-*` attributes (see `jump_attrs/2`): the
  code, the field, the block indexes, and whichever of the finding's args can
  narrow the target further (an example phrase, a word limit, a heading level,
  the broken paths). Without JavaScript the "block n" links still work as
  plain fragment links; the row itself does nothing, which is the honest
  fallback for a purely visual affordance.
  """
  attr :findings, :list, required: true
  attr :message_fn, :any, required: true
  attr :class, :any, default: nil

  def advisory_findings(assigns) do
    ~H"""
    <ul :if={@findings != []} class={["space-y-1", @class]}>
      <li
        :for={finding <- @findings}
        class={["flex items-start gap-1.5 text-xs", severity_tone(finding.severity)]}
      >
        <.icon name={severity_icon(finding.severity)} class="mt-0.5 size-3.5 shrink-0" />
        <span>
          <%!-- `type="button"`: the panel sits inside the editor's main
                <.form>, where the default type would submit it. --%>
          <button
            type="button"
            class="text-left underline-offset-2 hover:underline focus-visible:underline"
            title={gettext("Show this in the editor")}
            {jump_attrs(finding, Finding.block_indexes(finding, max_marked_blocks()))}
          >
            {@message_fn.(finding)}
          </button>
          <%!-- Findings that name specific blocks link straight to them; the
                editor gives every top-level block an `id="block-<index>"`. --%>
          <a
            :for={index <- Finding.block_indexes(finding, max_jump_links())}
            href={"#block-#{index}"}
            class="ml-1 underline underline-offset-2"
            {jump_attrs(finding, [index])}
          >
            {gettext("block %{position}", position: index + 1)}
          </a>
        </span>
      </li>
    </ul>
    """
  end

  defp max_jump_links, do: @max_jump_links
  defp max_marked_blocks, do: @max_marked_blocks

  @doc """
  The `data-jump-*` attributes for one finding — the contract with
  `assets/js/advisory_jump.js`.

  `indexes` is the block list to render, already capped by the caller. Absent
  values render no attribute at all (Phoenix drops nil attrs), so the client
  reads "no example phrase" as a missing key rather than an empty string.

  `hrefs` is JSON rather than a delimited list: a path is author-written text
  and can contain any delimiter we might pick.
  """
  @spec jump_attrs(Finding.t(), [non_neg_integer()]) :: map()
  def jump_attrs(%Finding{} = finding, indexes) do
    args = finding.args || %{}

    %{
      "data-advisory-jump" => true,
      "data-jump-code" => finding.code,
      "data-jump-field" => finding.field,
      "data-jump-blocks" => if(indexes != [], do: Enum.join(indexes, ",")),
      "data-jump-text" => args[:example],
      "data-jump-max" => args[:max],
      "data-jump-level" => args[:to],
      "data-jump-hrefs" => if(is_list(args[:paths]), do: Jason.encode!(args[:paths]))
    }
  end

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
