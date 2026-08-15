defmodule KilnCMSWeb.CalendarLive do
  @moduledoc """
  The **editorial calendar** (`/editor/calendar`): one time-ordered view of
  everything an editorial team plans around — scheduled publishes, embargo ends
  (split by what they will actually do), go-lives, review-due dates, task due
  dates, and release go-lives.

  The query lives in `KilnCMS.CMS.Calendar`; this module is the three ways of
  looking at it and the filters that narrow it. Editor-gated by the
  `:editor_routes` live session.

  ## Three views, one window

  * **Month** — the planning view. A grid of days, chips truncated, capped per
    cell with a "+N more" overflow so one busy Thursday cannot push December
    off the screen.
  * **Week** — the working view. Seven day columns, chips in full with their
    times, which is what you need when two things land on the same afternoon.
  * **List** — chronological, and the accessible baseline. It is also the
    mobile view: a seven-column grid on a phone is a horizontal scroll nobody
    wants, so the month/week grids are `hidden md:block` and the list carries
    small screens on its own.

  All three read the same `from`/`to` window off one `at` anchor, so switching
  view keeps your place.

  ## Live

  Mount subscribes to the org's calendar topic
  (`KilnCMS.CMS.Changes.BroadcastCalendar`), so any write that moves something
  plotted here — from this session, another editor's, the API, or a scheduler —
  re-queries the window. The message carries only an id: the window is small
  and the filters are server-side, so re-running the projection is cheaper and
  much simpler than working out whether that one id is in view.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.Changes.BroadcastCalendar
  alias KilnCMS.CMS.ContentTypes

  # Chips per day cell before the month grid collapses the rest into "+N more".
  # The cell is a fixed height so the grid stays a grid; four is what fits.
  @month_cell_chips 4

  @views ~w(month week list)
  @healths ~w(fresh due_soon due overdue expired)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        KilnCMS.PubSub,
        BroadcastCalendar.topic(socket.assigns.current_org.id)
      )
    end

    {:ok, assign(socket, :page_title, gettext("Calendar"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] in @views, do: params["view"], else: "month"
    at = parse_at(params)

    {:noreply,
     socket
     |> assign(:view, view)
     |> assign(:at, at)
     |> assign(:content_types, ContentTypes.all_for_org(socket.assigns.current_org))
     |> assign_filters(params)
     |> load_events()}
  end

  # A write landed somewhere in this org that the calendar plots. Re-query the
  # window rather than patching the one id in: the window is a month at most,
  # and reconciling one event against three views' worth of grouping is more
  # code than the query costs.
  @impl true
  def handle_info({:calendar_changed, _id}, socket) do
    {:noreply, load_events(socket)}
  end

  @impl true
  def handle_event("filter", params, socket) when is_map(params) do
    {:noreply, push_patch(socket, to: calendar_path(socket.assigns, filters_from_params(params)))}
  end

  # --- window -----------------------------------------------------------------

  # One anchor date drives all three views, so switching view keeps your place.
  # `month=YYYY-MM` is still accepted: it is what the first version of this page
  # shipped, and a bookmarked month should not silently land on today.
  defp parse_at(%{"at" => at}) when is_binary(at) do
    case Date.from_iso8601(at) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp parse_at(%{"month" => month}) when is_binary(month) do
    case Date.from_iso8601(month <> "-01") do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp parse_at(_params), do: Date.utc_today()

  # The half-open window each view asks the projection for.
  defp window("month", at) do
    first = Date.beginning_of_month(at)
    {midnight(first), midnight(Date.add(Date.end_of_month(at), 1))}
  end

  defp window("week", at) do
    first = Date.beginning_of_week(at)
    {midnight(first), midnight(Date.add(first, 7))}
  end

  # The list is "what's coming", anchored a week back so this morning's publish
  # is still on screen this afternoon.
  defp window("list", at), do: {midnight(Date.add(at, -7)), midnight(Date.add(at, 56))}

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp load_events(socket) do
    %{view: view, at: at, filters: filters} = socket.assigns
    {from, to} = window(view, at)

    events =
      KilnCMS.CMS.Calendar.events(
        socket.assigns.current_user,
        socket.assigns.current_org,
        from,
        to,
        filters
      )

    socket
    |> assign(:events, events)
    |> assign(:by_day, Enum.group_by(events, &DateTime.to_date(&1.at)))
    |> assign(:days, days(view, at))
  end

  # Month renders full weeks (Mon–Sun) covering the month, chunked into rows;
  # week renders one such row. The list needs no calendar scaffold at all.
  defp days("month", at) do
    first = at |> Date.beginning_of_month() |> Date.beginning_of_week()
    last = at |> Date.end_of_month() |> Date.end_of_week()

    first |> Date.range(last) |> Enum.chunk_every(7)
  end

  defp days("week", at) do
    first = Date.beginning_of_week(at)
    [Enum.to_list(Date.range(first, Date.add(first, 6)))]
  end

  defp days("list", _at), do: []

  # --- filters ----------------------------------------------------------------

  # Each filter is one value or "all". Lists would let an editor tick three
  # types at once, and the projection takes lists — but three dropdowns is the
  # whole filter bar in one row, and the URL stays something you can read.
  defp assign_filters(socket, params) do
    assign(socket, :filters, filters_from_params(params))
  end

  defp filters_from_params(params) do
    %{
      types: one_of(params["type"], nil),
      kinds: one_of(params["kind"], KilnCMS.CMS.Calendar.kinds()),
      health: one_of(params["health"], @healths)
    }
  end

  # `nil` (the projection's "everything") for a missing or "all" value, and for
  # anything not in the allowed set — a hand-edited URL naming a lane that does
  # not exist should show the whole calendar, not an empty one.
  defp one_of(value, _allowed) when value in [nil, "", "all"], do: nil

  defp one_of(value, nil), do: [value]

  defp one_of(value, allowed) do
    case Enum.find(allowed, &(to_string(&1) == value)) do
      nil -> nil
      found -> [found]
    end
  end

  defp calendar_path(assigns, filters) do
    query =
      [
        view: assigns.view,
        at: Date.to_iso8601(assigns.at),
        type: filter_value(filters.types),
        kind: filter_value(filters.kinds),
        health: filter_value(filters.health)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/editor/calendar?#{query}"
  end

  defp filter_value(nil), do: nil
  defp filter_value([value]), do: to_string(value)

  defp shift(assigns, offset) do
    at =
      case assigns.view do
        "month" -> Date.shift(assigns.at, month: offset)
        "week" -> Date.add(assigns.at, offset * 7)
        "list" -> Date.shift(assigns.at, month: offset)
      end

    calendar_path(%{assigns | at: at}, assigns.filters)
  end

  defp with_view(assigns, view), do: calendar_path(%{assigns | view: view}, assigns.filters)

  # --- labels -----------------------------------------------------------------

  defp window_label(%{view: "week", at: at}) do
    first = Date.beginning_of_week(at)
    last = Date.add(first, 6)

    if first.month == last.month do
      "#{Calendar.strftime(first, "%-d")}–#{Calendar.strftime(last, "%-d %B %Y")}"
    else
      "#{Calendar.strftime(first, "%-d %b")} – #{Calendar.strftime(last, "%-d %b %Y")}"
    end
  end

  defp window_label(%{at: at}), do: Calendar.strftime(at, "%B %Y")

  # The nav steps a month in month/list view and a week in week view, so the
  # labels have to say which — a screen reader user pressing "Next month" and
  # moving seven days is a bug they cannot see.
  defp prev_label(%{view: "week"}), do: gettext("Previous week")
  defp prev_label(_assigns), do: gettext("Previous month")
  defp next_label(%{view: "week"}), do: gettext("Next week")
  defp next_label(_assigns), do: gettext("Next month")

  # Two label sets, on purpose. A chip is read *after* its title, so it reads as
  # a sentence — "Autumn launch — Page publishes". A legend key and a filter
  # option are read on their own, where a bare verb ("publishes") is a fragment.
  defp lane_label(:publish), do: gettext("Scheduled publish")
  defp lane_label(:published), do: gettext("Went live")
  defp lane_label(:unpublish), do: gettext("Scheduled unpublish")
  defp lane_label(:archive), do: gettext("Scheduled archive")
  defp lane_label(:expire), do: gettext("Expired (flagged)")
  defp lane_label(:review_due), do: gettext("Review due")
  defp lane_label(:task_due), do: gettext("Task due")
  defp lane_label(:release_scheduled), do: gettext("Release go-live")
  defp lane_label(:release_published), do: gettext("Release shipped")

  defp kind_label(:publish), do: gettext("publishes")
  defp kind_label(:unpublish), do: gettext("unpublishes")
  defp kind_label(:archive), do: gettext("archives")
  defp kind_label(:expire), do: gettext("expires")
  defp kind_label(:published), do: gettext("went live")
  defp kind_label(:review_due), do: gettext("review due")
  defp kind_label(:task_due), do: gettext("task due")
  defp kind_label(:release_scheduled), do: gettext("release goes live")
  defp kind_label(:release_published), do: gettext("release shipped")

  defp kind_class(:publish), do: "border-warning/40 bg-warning/10"
  defp kind_class(:unpublish), do: "border-error/40 bg-error/10"
  defp kind_class(:archive), do: "border-error/40 bg-error/10"
  defp kind_class(:expire), do: "border-error/60 bg-error/15 font-medium"
  defp kind_class(:published), do: "border-success/40 bg-success/10"
  defp kind_class(:review_due), do: "border-warning/50 bg-warning/15"
  defp kind_class(:task_due), do: "border-info/40 bg-info/10"
  defp kind_class(:release_scheduled), do: "border-primary/50 bg-primary/10 font-medium"
  defp kind_class(:release_published), do: "border-primary/30 bg-primary/5"

  # A release chip goes to the release, not to a content editor — it isn't a
  # content record and has no `{type, id}` editor route.
  defp event_path(%{type: :release, id: id}), do: ~p"/editor/releases/#{id}"
  defp event_path(%{type: type, id: id}), do: ~p"/editor/content/#{type}/#{id}"

  defp today?(date), do: date == Date.utc_today()

  # --- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:calendar}
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">{gettext("Editorial calendar")}</h1>

          <div class="flex flex-wrap items-center gap-2">
            <div class="join" role="group" aria-label={gettext("Calendar view")}>
              <.link
                :for={
                  {value, label} <- [
                    {"month", gettext("Month")},
                    {"week", gettext("Week")},
                    {"list", gettext("List")}
                  ]
                }
                patch={with_view(assigns, value)}
                aria-current={@view == value && "page"}
                class={[
                  "btn btn-sm join-item",
                  if(@view == value, do: "btn-primary", else: "btn-default")
                ]}
              >
                {label}
              </.link>
            </div>

            <.link
              patch={shift(assigns, -1)}
              class="btn btn-sm btn-default"
              aria-label={prev_label(assigns)}
            >
              &larr;
            </.link>
            <span class="min-w-40 text-center text-sm font-medium">{window_label(assigns)}</span>
            <.link
              patch={shift(assigns, 1)}
              class="btn btn-sm btn-default"
              aria-label={next_label(assigns)}
            >
              &rarr;
            </.link>
            <.link
              patch={calendar_path(%{assigns | at: Date.utc_today()}, @filters)}
              class="btn btn-sm btn-default"
            >
              {gettext("Today")}
            </.link>
          </div>
        </div>

        <.filter_bar
          content_types={@content_types}
          filters={@filters}
          view={@view}
          at={@at}
        />

        <.legend />

        <%!-- The grids are desktop-only and the list carries small screens on
              its own: seven columns on a phone is a horizontal scroll. When the
              editor has explicitly chosen List, it shows at every width. --%>
        <div :if={@view in ["month", "week"]} class="hidden md:block">
          <.grid days={@days} by_day={@by_day} view={@view} at={@at} />
        </div>
        <div :if={@view in ["month", "week"]} class="md:hidden">
          <.event_list events={@events} />
        </div>
        <div :if={@view == "list"}>
          <.event_list events={@events} />
        </div>
      </div>
    </Layouts.console>
    """
  end

  attr :content_types, :list, required: true
  attr :filters, :map, required: true
  attr :view, :string, required: true
  attr :at, :any, required: true

  defp filter_bar(assigns) do
    ~H"""
    <form phx-change="filter" class="flex flex-wrap items-end gap-3">
      <input type="hidden" name="view" value={@view} />
      <input type="hidden" name="at" value={Date.to_iso8601(@at)} />

      <label class="flex flex-col gap-1 text-xs text-base-content/70">
        {gettext("Type")}
        <select name="type" class="select select-sm select-bordered">
          <option value="all" selected={is_nil(@filters.types)}>{gettext("All types")}</option>
          <option
            :for={ct <- @content_types}
            value={to_string(ct.type)}
            selected={@filters.types == [to_string(ct.type)]}
          >
            {ct.label}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs text-base-content/70">
        {gettext("Lane")}
        <select name="kind" class="select select-sm select-bordered">
          <option value="all" selected={is_nil(@filters.kinds)}>{gettext("All lanes")}</option>
          <option
            :for={kind <- KilnCMS.CMS.Calendar.kinds()}
            value={to_string(kind)}
            selected={@filters.kinds == [kind]}
          >
            {lane_label(kind)}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs text-base-content/70">
        {gettext("Health")}
        <select name="health" class="select select-sm select-bordered">
          <option value="all" selected={is_nil(@filters.health)}>{gettext("Any health")}</option>
          <option
            :for={health <- [:due_soon, :due, :overdue, :expired, :fresh]}
            value={to_string(health)}
            selected={@filters.health == [health]}
          >
            {health_label(health)}
          </option>
        </select>
      </label>
    </form>
    """
  end

  defp legend(assigns) do
    ~H"""
    <p class="flex flex-wrap gap-4 text-xs text-base-content/70">
      <span :for={kind <- KilnCMS.CMS.Calendar.kinds()} class="flex items-center gap-1.5">
        <span class={["inline-block size-3 rounded border", kind_class(kind)]} />
        {lane_label(kind)}
      </span>
    </p>
    """
  end

  attr :days, :list, required: true
  attr :by_day, :map, required: true
  attr :view, :string, required: true
  attr :at, :any, required: true

  defp grid(assigns) do
    ~H"""
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
          <tr :for={week <- @days}>
            <td
              :for={day <- week}
              class={[
                "border border-base-content/10 p-1 align-top",
                if(@view == "week", do: "h-64", else: "h-28 min-w-28"),
                day.month != @at.month && @view == "month" && "bg-base-200/40 text-base-content/40",
                today?(day) && "ring-1 ring-inset ring-primary"
              ]}
            >
              <div class={["mb-1 text-xs", today?(day) && "font-bold text-primary"]}>
                {day.day}
              </div>
              <.day_chips events={Map.get(@by_day, day, [])} view={@view} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :events, :list, required: true
  attr :view, :string, required: true

  defp day_chips(assigns) do
    # Week columns are tall enough to show the day in full; month cells are not,
    # and a cell that grew with its contents would break the grid it is part of.
    {shown, hidden} =
      if assigns.view == "week",
        do: {assigns.events, []},
        else: Enum.split(assigns.events, @month_cell_chips)

    assigns = assigns |> assign(:shown, shown) |> assign(:hidden, hidden)

    ~H"""
    <ul class="space-y-1">
      <li :for={ev <- @shown}>
        <.link
          navigate={event_path(ev)}
          class={[
            "block truncate rounded border px-1.5 py-0.5 text-xs hover:opacity-80",
            kind_class(ev.kind)
          ]}
          title={"#{ev.title} — #{ev.label} #{kind_label(ev.kind)}"}
        >
          <span :if={@view == "week"} class="mr-1 tabular-nums opacity-70">
            {Calendar.strftime(ev.at, "%H:%M")}
          </span>
          {ev.title}
        </.link>
      </li>
      <%!-- Not a disclosure: expanding in place would resize the cell and shift
            every row below it. The overflow says how much is hidden and the
            week view is one click away, where it all fits. --%>
      <li :if={@hidden != []} class="px-1.5 text-xs text-base-content/60">
        {ngettext("+%{count} more", "+%{count} more", length(@hidden), count: length(@hidden))}
      </li>
    </ul>
    """
  end

  attr :events, :list, required: true

  defp event_list(assigns) do
    ~H"""
    <div :if={@events == []} class="card card-pad text-center text-sm text-base-content/70">
      <p class="font-medium">{gettext("Nothing scheduled in this window")}</p>
      <p class="mt-1">
        {gettext("Schedule a publish, set an embargo end, or give content a review cadence.")}
      </p>
      <div class="mt-3">
        <.link navigate={~p"/editor"} class="btn btn-sm btn-primary">{gettext("Go to content")}</.link>
      </div>
    </div>

    <ol
      :if={@events != []}
      class="divide-y divide-base-content/10 rounded-xl border border-base-content/10"
    >
      <li
        :for={
          {date, events} <-
            Enum.group_by(@events, &DateTime.to_date(&1.at)) |> Enum.sort_by(&elem(&1, 0), Date)
        }
        class="p-3"
      >
        <p class={[
          "mb-2 text-xs font-semibold uppercase tracking-wide",
          if(today?(date), do: "text-primary", else: "text-base-content/60")
        ]}>
          {Calendar.strftime(date, "%A %-d %B")}
          <span :if={today?(date)}>· {gettext("today")}</span>
        </p>
        <ul class="space-y-1.5">
          <li :for={ev <- events} class="flex flex-wrap items-center gap-2">
            <span class="w-12 shrink-0 text-xs tabular-nums text-base-content/60">
              {Calendar.strftime(ev.at, "%H:%M")}
            </span>
            <span class={["inline-block size-3 shrink-0 rounded border", kind_class(ev.kind)]} />
            <.link
              navigate={event_path(ev)}
              class="min-w-0 flex-1 truncate font-medium hover:underline"
            >
              {ev.title}
            </.link>
            <span class="shrink-0 text-xs text-base-content/70">
              {ev.label} {kind_label(ev.kind)}
            </span>
            <.health_badge health={ev.health} class="shrink-0" />
          </li>
        </ul>
      </li>
    </ol>
    """
  end
end
