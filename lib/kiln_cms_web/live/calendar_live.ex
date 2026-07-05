defmodule KilnCMSWeb.CalendarLive do
  @moduledoc """
  The **editorial calendar** (`/editor/calendar`): a month grid plotting every
  content type's scheduled publishes (`scheduled_at`), scheduled unpublishes
  (`unpublish_at`, the embargo end), and go-live dates (`published_at`) —
  compiled types and admin-defined dynamic entries alike. Each chip links to
  the record's editor. Editor-gated by the `:editor_routes` live session.
  """
  use KilnCMSWeb, :live_view

  import Ash.Expr

  alias KilnCMS.CMS.ContentTypes

  # Per-type cap for one month's events — far above any real editorial volume,
  # but keeps a pathological month bounded. log-free: nothing is dropped
  # silently in practice; the grid simply shows what fits.
  @per_type_limit 300

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Calendar"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    month = parse_month(params["month"])

    {:noreply,
     socket
     |> assign(:month, month)
     |> assign(:weeks, weeks(month))
     |> assign(:events, events(socket.assigns.current_user, month))}
  end

  # --- data -------------------------------------------------------------------

  # "YYYY-MM" → first day of that month; anything else → the current month.
  defp parse_month(param) do
    with param when is_binary(param) <- param,
         {:ok, date} <- Date.from_iso8601(param <> "-01") do
      date
    else
      _ -> Date.utc_today() |> Date.beginning_of_month()
    end
  end

  # All events in the month, grouped by day: %{~D[...] => [event, ...]}.
  # One record can contribute several events (went live + embargo end).
  defp events(actor, month) do
    from = DateTime.new!(month, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(Date.end_of_month(month), 1), ~T[00:00:00], "Etc/UTC")

    (ContentTypes.all() ++ ContentTypes.dynamic_all())
    |> Enum.flat_map(&month_events(&1, actor, from, to))
    |> Enum.sort_by(& &1.at, DateTime)
    |> Enum.group_by(&DateTime.to_date(&1.at))
  end

  defp month_events(ct, actor, from, to) do
    ct
    |> ContentTypes.list!(
      actor: actor,
      query: [
        filter:
          expr(
            (scheduled_at >= ^from and scheduled_at < ^to) or
              (unpublish_at >= ^from and unpublish_at < ^to) or
              (published_at >= ^from and published_at < ^to)
          ),
        select: [:id, :title, :state, :scheduled_at, :unpublish_at, :published_at],
        limit: @per_type_limit
      ]
    )
    |> Enum.flat_map(&record_events(ct, &1, from, to))
  end

  # A record's events: each date field that falls in the window while the
  # record is in a state where that date is still meaningful.
  defp record_events(ct, record, from, to) do
    for {kind, at, states} <- [
          {:publish, record.scheduled_at, [:draft, :in_review]},
          {:unpublish, record.unpublish_at, [:published]},
          {:published, record.published_at, [:published]}
        ],
        record.state in states,
        in_window?(at, from, to) do
      %{id: record.id, type: ct.type, label: ct.label, title: record.title, kind: kind, at: at}
    end
  end

  defp in_window?(nil, _from, _to), do: false

  defp in_window?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  # The grid: full weeks (Mon–Sun) covering the month.
  defp weeks(month) do
    first = Date.beginning_of_week(month)
    last = month |> Date.end_of_month() |> Date.end_of_week()

    first
    |> Date.range(last)
    |> Enum.chunk_every(7)
  end

  defp month_label(month), do: Calendar.strftime(month, "%B %Y")

  defp shift_month(month, offset), do: month |> Date.shift(month: offset) |> month_param()
  defp month_param(month), do: Calendar.strftime(month, "%Y-%m")

  defp kind_label(:publish), do: gettext("publishes")
  defp kind_label(:unpublish), do: gettext("unpublishes")
  defp kind_label(:published), do: gettext("went live")

  defp kind_class(:publish), do: "border-warning/40 bg-warning/10"
  defp kind_class(:unpublish), do: "border-error/40 bg-error/10"
  defp kind_class(:published), do: "border-success/40 bg-success/10"

  # --- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:calendar}
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">{gettext("Editorial calendar")}</h1>
          <div class="flex items-center gap-2">
            <.link
              patch={~p"/editor/calendar?month=#{shift_month(@month, -1)}"}
              class="btn btn-sm btn-default"
              aria-label={gettext("Previous month")}
            >
              &larr;
            </.link>
            <span class="min-w-36 text-center text-sm font-medium">{month_label(@month)}</span>
            <.link
              patch={~p"/editor/calendar?month=#{shift_month(@month, 1)}"}
              class="btn btn-sm btn-default"
              aria-label={gettext("Next month")}
            >
              &rarr;
            </.link>
            <.link patch={~p"/editor/calendar"} class="btn btn-sm btn-default">
              {gettext("Today")}
            </.link>
          </div>
        </div>

        <p class="flex flex-wrap gap-4 text-xs text-base-content/70">
          <span class="flex items-center gap-1.5">
            <span class={["inline-block size-3 rounded border", kind_class(:publish)]} />
            {gettext("Scheduled publish")}
          </span>
          <span class="flex items-center gap-1.5">
            <span class={["inline-block size-3 rounded border", kind_class(:unpublish)]} />
            {gettext("Scheduled unpublish")}
          </span>
          <span class="flex items-center gap-1.5">
            <span class={["inline-block size-3 rounded border", kind_class(:published)]} />
            {gettext("Went live")}
          </span>
        </p>

        <div class="overflow-x-auto">
          <table class="w-full table-fixed border-collapse text-sm">
            <thead>
              <tr>
                <th
                  :for={
                    day <- [
                      gettext("Mon"),
                      gettext("Tue"),
                      gettext("Wed"),
                      gettext("Thu"),
                      gettext("Fri"),
                      gettext("Sat"),
                      gettext("Sun")
                    ]
                  }
                  class="border border-base-content/10 px-2 py-1 text-left text-xs font-semibold uppercase tracking-wide text-base-content/60"
                >
                  {day}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={week <- @weeks}>
                <td
                  :for={day <- week}
                  class={[
                    "h-24 min-w-28 border border-base-content/10 p-1 align-top",
                    day.month != @month.month && "bg-base-200/40 text-base-content/40"
                  ]}
                >
                  <div class={[
                    "mb-1 text-xs",
                    day == Date.utc_today() && "font-bold text-primary"
                  ]}>
                    {day.day}
                  </div>
                  <ul class="space-y-1">
                    <li :for={ev <- Map.get(@events, day, [])}>
                      <.link
                        navigate={~p"/editor/content/#{ev.type}/#{ev.id}"}
                        class={[
                          "block truncate rounded border px-1.5 py-0.5 text-xs hover:opacity-80",
                          kind_class(ev.kind)
                        ]}
                        title={"#{ev.title} — #{ev.label} #{kind_label(ev.kind)}"}
                      >
                        {ev.title}
                      </.link>
                    </li>
                  </ul>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
