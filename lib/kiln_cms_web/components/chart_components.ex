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
      |> assign_new(:value_header, fn -> gettext("Views") end)

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
end
