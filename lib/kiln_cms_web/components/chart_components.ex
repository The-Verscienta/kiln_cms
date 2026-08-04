defmodule KilnCMSWeb.ChartComponents do
  @moduledoc """
  Server-rendered chart primitives for the console.

  Inline SVG, no JavaScript and no charting dependency — the same grain as
  `KilnCMSWeb.CoreComponents.trigram/1`. Geometry is integer arithmetic done
  here, so a chart renders identically on first paint and needs no client hook.

  Accessibility is the point of the wrapper markup: the SVG is decorative
  (`aria-hidden`) and a visually-hidden `<table>` carries the actual numbers, so
  a screen-reader user gets every data point rather than a one-line summary.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  # Bar geometry in viewBox units: a 6-wide bar in a 10-wide slot leaves a
  # 4-unit gutter. The box is 100 tall; bars are capped at 92 so the tallest
  # still clears the top edge.
  @slot 10
  @bar 6
  @height 100
  @max_bar 92

  @doc """
  Bar chart of a daily counter series.

  `series` is a list of `%{day: Date.t(), views: integer}`, oldest first — the
  caller is responsible for zero-filling gaps, since a missing day must render
  as a zero-height bar rather than shifting the timeline.
  """
  attr :series, :list, required: true
  attr :label, :string, required: true, doc: "caption for the visually-hidden data table"
  attr :value_header, :string, default: nil
  attr :class, :any, default: nil

  def bar_chart(assigns) do
    # Module attributes aren't in scope inside ~H (there, `@x` means
    # `assigns.x`), so the geometry constants are assigned rather than inlined.
    assigns =
      assigns
      |> assign(:max, assigns.series |> Enum.map(& &1.views) |> Enum.max(fn -> 0 end))
      |> assign(:width, max(length(assigns.series) * @slot, @slot))
      |> assign(:bar, @bar)
      |> assign(:height, @height)
      |> assign(:baseline_y, @height - 1)
      |> assign(:value_header, assigns.value_header || gettext("Views"))

    ~H"""
    <div class={@class}>
      <%!-- preserveAspectRatio="none" lets the bars stretch to any container
            width. Safe only because every mark is a filled rect — a stroked
            line or circle would distort under non-uniform scaling. --%>
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="h-40 w-full"
        aria-hidden="true"
        focusable="false"
      >
        <g class="text-primary-ink" fill="currentColor">
          <rect
            :for={{point, i} <- Enum.with_index(@series)}
            x={bar_x(i)}
            y={@height - bar_height(point.views, @max)}
            width={@bar}
            height={bar_height(point.views, @max)}
            rx="1"
          >
            <title>{Date.to_iso8601(point.day)}: {point.views}</title>
          </rect>
        </g>
        <rect
          x="0"
          y={@baseline_y}
          width={@width}
          height="1"
          class="text-base-content/20"
          fill="currentColor"
        />
      </svg>

      <%!-- The accessible representation. `sr-only` rather than `hidden` so it
            stays in the accessibility tree; a real table (caption + scope) means
            a screen reader can walk the values instead of hearing a summary. --%>
      <table class="sr-only">
        <caption>{@label}</caption>
        <thead>
          <tr>
            <th scope="col">{gettext("Day")}</th>
            <th scope="col">{@value_header}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={point <- @series}>
            <th scope="row">{Date.to_iso8601(point.day)}</th>
            <td>{point.views}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp bar_x(index), do: index * @slot + div(@slot - @bar, 2)

  # A day with views is never invisible: it floors at 1 unit rather than
  # rounding to nothing. A genuine zero stays flat so gaps read as gaps.
  defp bar_height(0, _max), do: 0
  defp bar_height(_views, 0), do: 0
  defp bar_height(views, max), do: max(round(views / max * @max_bar), 1)

  @doc """
  Bar chart of a category-count breakdown (e.g. referrer sources, #620) — the
  non-time-series sibling of `bar_chart/1`, sharing its geometry and
  accessible-table shape.

  `entries` is `[%{source: atom(), label: String.t(), display: String.t() |
  integer(), bar_value: non_neg_integer()}]`, in render order. `display` is
  what a person reads — it may already be a low-count-suppressed `"< n"`
  string (see `KilnCMS.Analytics.suppress_low_count/1`) — while `bar_value`
  drives the bar's height. The two are deliberately allowed to diverge: the
  **caller** is responsible for clamping `bar_value` for any entry whose
  `display` is suppressed, so this chart can never become a side channel for
  a count its own label just hid.
  """
  attr :entries, :list, required: true
  attr :label, :string, required: true, doc: "caption for the visually-hidden data table"
  attr :value_header, :string, default: nil
  attr :class, :any, default: nil

  def category_chart(assigns) do
    assigns =
      assigns
      |> assign(:max, assigns.entries |> Enum.map(& &1.bar_value) |> Enum.max(fn -> 0 end))
      |> assign(:width, max(length(assigns.entries) * @slot, @slot))
      |> assign(:bar, @bar)
      |> assign(:height, @height)
      |> assign(:baseline_y, @height - 1)
      |> assign(:value_header, assigns.value_header || gettext("Count"))

    ~H"""
    <div class={@class}>
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="h-40 w-full"
        aria-hidden="true"
        focusable="false"
      >
        <rect
          :for={{entry, i} <- Enum.with_index(@entries)}
          x={bar_x(i)}
          y={@height - bar_height(entry.bar_value, @max)}
          width={@bar}
          height={bar_height(entry.bar_value, @max)}
          rx="1"
          class={source_class(entry.source)}
          fill="currentColor"
        >
          <title>{entry.label}: {entry.display}</title>
        </rect>
        <rect
          x="0"
          y={@baseline_y}
          width={@width}
          height="1"
          class="text-base-content/20"
          fill="currentColor"
        />
      </svg>

      <table class="sr-only">
        <caption>{@label}</caption>
        <thead>
          <tr>
            <th scope="col">{gettext("Source")}</th>
            <th scope="col">{@value_header}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={entry <- @entries}>
            <th scope="row">{entry.label}</th>
            <td>{entry.display}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Compact single-line referrer breakdown sized for a table cell (#620) — a
  stacked bar, not a full chart, meant to render once per row in a table of
  up to fifty. Segment **width** is proportional to `bar_value` (the same
  caller-clamped-for-suppression contract as `category_chart/1`'s), but the
  numbers a person can actually read — on hover (`title`) and for a screen
  reader (the trailing `sr-only` list) — always show `display`, which may be
  a suppressed `"< n"` string. A sighted user comparing segment widths and a
  screen-reader user hearing the list get the same information, not more or
  less of it.
  """
  attr :entries, :list, required: true
  attr :label, :string, required: true, doc: "prefix read before the sr-only breakdown list"
  attr :class, :any, default: nil

  def referrer_bar(assigns) do
    assigns =
      assigns
      |> assign(:total, assigns.entries |> Enum.map(& &1.bar_value) |> Enum.sum())
      |> assign(:segments, Enum.filter(assigns.entries, &(&1.bar_value > 0)))

    ~H"""
    <div class={@class}>
      <div class="flex h-2 w-full overflow-hidden rounded bg-base-content/10" aria-hidden="true">
        <span
          :for={entry <- @segments}
          class={["block h-full", source_class(entry.source)]}
          style={"width: #{segment_pct(entry.bar_value, @total)}%; background-color: currentColor"}
          title={"#{entry.label}: #{entry.display}"}
        ></span>
      </div>
      <span class="sr-only">
        {@label}: <span :for={entry <- @entries}>{entry.label} {entry.display}; </span>
      </span>
    </div>
    """
  end

  defp segment_pct(_value, 0), do: 0
  defp segment_pct(value, total), do: Float.round(value / total * 100, 1)

  # Fixed per-source colour so the site-wide chart's legend and every per-row
  # bar agree — an operator scanning the table shouldn't have to re-learn
  # "which colour is search" per row. `text-*` classes because both callers
  # above set `fill`/`background-color: currentColor` rather than a literal
  # colour, so a theme change only has to update this one function.
  defp source_class(:direct), do: "text-base-content/50"
  defp source_class(:internal), do: "text-info"
  defp source_class(:search), do: "text-primary"
  defp source_class(:social), do: "text-secondary"
  defp source_class(:other), do: "text-base-content/25"
end
