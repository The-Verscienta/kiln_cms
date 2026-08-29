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

  A burst of writes (a bulk import, a release going out, a scheduler sweep —
  or simply many things saving at once) queues one `:calendar_changed` per
  write, and each one asks for exactly the same thing: re-run the window
  query. `handle_info/2` drains every additional `:calendar_changed` already
  waiting in the mailbox before it re-queries, so a burst of N writes costs
  one re-query rather than N run back to back. Without that, this process's
  own mailbox — not the database — becomes the bottleneck: every message is
  handled strictly in arrival order, so a `render_click`/`render` call queued
  behind a long run of stale, superseded re-queries waits for all of them
  first. That is what a heavily-loaded shared org (the test suite's default
  org, or in principle a very busy production one) turns into an apparent
  hang: not a slow query and not a deadlock, just a mailbox that fell behind
  its own reactivity and had no way to catch up.
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

    {:ok,
     socket
     |> assign(:page_title, gettext("Calendar"))
     # Present from the first render: an aria-live region inserted later is not
     # announced by every screen reader, so it has to exist (empty) up front.
     |> assign(:announcement, nil)}
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
  # window rather than patching the one id in: the window is six weeks at most,
  # and reconciling one event against three views' worth of grouping is more
  # code than the query costs.
  #
  # `drain_calendar_changed/1` first, so a burst already queued behind this
  # message collapses into the one re-query it actually needs (see the
  # moduledoc's "Live" section) instead of running once per message.
  #
  # The telemetry event is the coalescing made observable: one event per
  # re-query, carrying how many `:calendar_changed` messages it answered. A
  # busy org shows up as a high `messages` summary, a broken drain as the
  # event firing once per message with `messages: 1` — and the burst test
  # counts these events rather than repo query telemetry, because one
  # re-query is one *logical* query but several physical ones (one per
  # content type, plus the dynamic-type registry, tasks and releases).
  @impl true
  def handle_info({:calendar_changed, _id}, socket) do
    drained = drain_calendar_changed(0)

    :telemetry.execute(
      [:kiln_cms, :calendar, :requery],
      %{messages: drained + 1},
      %{org_id: socket.assigns.current_org.id}
    )

    {:noreply, load_events(socket)}
  end

  # Non-blocking: `after 0` returns immediately once the mailbox holds no more
  # `:calendar_changed` messages, so this costs nothing beyond a mailbox scan
  # when writes are not currently bursting. Returns how many messages it ate.
  defp drain_calendar_changed(count) do
    receive do
      {:calendar_changed, _id} -> drain_calendar_changed(count + 1)
    after
      0 -> count
    end
  end

  @impl true
  def handle_event("filter", params, socket) when is_map(params) do
    {:noreply, push_patch(socket, to: calendar_path(socket.assigns, filters_from_params(params)))}
  end

  # Drag or arrow-key reschedule. Both paths send the same shape — the target
  # date — because two shapes into one handler is how a guard ends up silently
  # not matching one of them (#764).
  def handle_event(
        "reschedule",
        %{"id" => id, "type" => type, "kind" => kind, "date" => date},
        socket
      )
      when is_binary(id) and is_binary(type) and is_binary(kind) and is_binary(date) do
    # The event must be one currently in this editor's window. That is not
    # belt-and-braces: the window was built by a policy-scoped, org-scoped read,
    # so looking the event up here means a socket cannot move a record it could
    # not already see — and it is also where the chip's existing time-of-day
    # comes from, so a drag moves the day and leaves 09:00 alone.
    #
    # `refuse_undraggable/1` is the server-side twin of `data-reschedulable`: the
    # markup only offers a handle on draggable lanes, but the payload names its
    # own kind, so a `review_due` or `published` chip pushed by hand would
    # otherwise reach `do_reschedule/3`, which has no clause for it.
    with {:ok, event} <- find_event(socket.assigns.events, id, kind),
         :ok <- refuse_undraggable(event),
         {:ok, date} <- parse_date(date),
         :ok <- refuse_past(at_on(event, date)),
         {:ok, message} <- do_reschedule(event, date, socket) do
      {:noreply, socket |> announce(message) |> load_events()}
    else
      {:error, message} ->
        # Re-render from the server's state, which snaps the optimistically
        # moved chip back to where the data still says it belongs.
        {:noreply, socket |> announce(message) |> put_flash(:error, message) |> load_events()}
    end
  end

  def handle_event("mark_reviewed", %{"id" => id, "type" => type}, socket)
      when is_binary(id) and is_binary(type) do
    with {:ok, event} <- find_event(socket.assigns.events, id, "review_due"),
         {:ok, record} <- fetch_record(event, socket),
         {:ok, _record} <-
           ContentTypes.transition(event.type, "mark_reviewed", record,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ) do
      message = gettext("Marked “%{title}” reviewed.", title: event.title)
      {:noreply, socket |> announce(message) |> put_flash(:info, message) |> load_events()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, socket |> announce(message) |> put_flash(:error, message)}

      {:error, error} ->
        message = error_message(error)
        {:noreply, socket |> announce(message) |> put_flash(:error, message)}
    end
  end

  # --- writes -----------------------------------------------------------------

  # Which lanes can be dragged, and what each one actually writes.
  #
  # `:published` and `:release_published` are absent because they are history —
  # you cannot reschedule something that already happened.
  #
  # `:review_due` is absent for a subtler reason, and it is a deliberate
  # departure from the plan, which asked for it. `due_at` is *derived* from
  # `last_reviewed_at` and the cadence. Dragging it could only write one of
  # those two: moving `last_reviewed_at` forges an attestation — the one thing
  # the whole design refuses to let anything but a human review do — and
  # changing `review_after_days` alters the cadence permanently to move a single
  # deadline. Neither is what "give me another week" means, so the chip offers
  # "Mark reviewed" instead, which resets the clock honestly.
  #
  # `:task_due` is absent because the projection carries a task's *content* id
  # (the chip links to the content), so there is nothing here to address the
  # task by. Tasks are rescheduled from the task list.
  @reschedulable ~w(publish unpublish archive expire release_scheduled)

  defp do_reschedule(%{kind: :release_scheduled} = event, date, socket) do
    with {:ok, release} <-
           KilnCMS.CMS.get_release(event.id,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ),
         {:ok, _release} <-
           KilnCMS.CMS.schedule_release(release, %{scheduled_at: at_on(event, date)},
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ) do
      {:ok, moved_message(event, date)}
    else
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp do_reschedule(event, date, socket) do
    attrs =
      case event.kind do
        :publish -> %{scheduled_at: at_on(event, date)}
        kind when kind in [:unpublish, :archive, :expire] -> %{unpublish_at: at_on(event, date)}
      end

    with {:ok, record} <- fetch_record(event, socket),
         {:ok, _record} <-
           ContentTypes.update(event.type, record, attrs,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org
           ) do
      {:ok, moved_message(event, date)}
    else
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp fetch_record(event, socket) do
    ContentTypes.get_record(event.type, event.id,
      actor: socket.assigns.current_user,
      tenant: socket.assigns.current_org
    )
  end

  # The new day, carrying the chip's existing time of day — a 09:00 publish
  # dragged to Thursday is a 09:00 Thursday publish, not a midnight one.
  defp at_on(event, date), do: DateTime.new!(date, DateTime.to_time(event.at), "Etc/UTC")

  defp find_event(events, id, kind) do
    case Enum.find(events, &(&1.id == id and to_string(&1.kind) == kind)) do
      nil -> {:error, gettext("That item is no longer on the calendar — reload to see why.")}
      event -> {:ok, event}
    end
  end

  defp refuse_undraggable(event) do
    if reschedulable?(event) do
      :ok
    else
      {:error, gettext("That item can't be moved by dragging.")}
    end
  end

  defp parse_date(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, gettext("That is not a date this calendar can move something to.")}
    end
  end

  # Refused uniformly rather than per lane. A backwards drag is nearly always a
  # slip, and every lane's past date means something abrupt and irreversible-ish
  # — a publish that fires within the minute, an embargo end that takes a live
  # page down now. "Nothing happened, here is why" is the better answer to a
  # slip than either of those.
  #
  # Judged on the full timestamp the move would write, not the day: a drop onto
  # *today* keeps the chip's time of day, so a 09:00 chip dropped at 15:00
  # would be a publish six hours in the past — exactly the abrupt thing above.
  defp refuse_past(%DateTime{} = at) do
    if DateTime.before?(at, DateTime.utc_now()) do
      {:error, gettext("Can't reschedule into the past.")}
    else
      :ok
    end
  end

  defp moved_message(event, date) do
    gettext("Moved “%{title}” to %{date}.",
      title: event.title,
      date: Calendar.strftime(date, "%-d %B %Y")
    )
  end

  defp error_message(message) when is_binary(message), do: message
  defp error_message(%{} = error), do: Exception.message(error)

  # The screen-reader channel for a change that is otherwise only visible as a
  # chip moving. Assigned rather than flashed for the success case: a toast per
  # drag while rearranging a week is noise, but a silent move is unusable
  # without sight of the grid.
  defp announce(socket, message), do: assign(socket, :announcement, message)

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
  #
  # The month window is the *rendered grid*, not the calendar month: `days/2`
  # pads the month out to full Mon–Sun weeks, and every one of those padding
  # cells is a drop target. Querying only the month proper meant a chip dragged
  # onto a trailing 2 September cell while viewing August was written and then
  # vanished from the grid — the re-query never fetched it — and anything already
  # scheduled on a padding day never drew a chip at all.
  defp window("month", at) do
    {midnight(grid_first(at)), midnight(Date.add(grid_last(at), 1))}
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
    at |> grid_first() |> Date.range(grid_last(at)) |> Enum.chunk_every(7)
  end

  defp days("week", at) do
    first = Date.beginning_of_week(at)
    [Enum.to_list(Date.range(first, Date.add(first, 6)))]
  end

  defp days("list", _at), do: []

  defp grid_first(at), do: at |> Date.beginning_of_month() |> Date.beginning_of_week()
  defp grid_last(at), do: at |> Date.end_of_month() |> Date.end_of_week()

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

  # Nine lanes over five accent tones, so two pairs need more than hue to tell
  # them apart — and both pairs were, briefly, indistinguishable on screen while
  # reading as distinct in the legend, which is worse than not splitting them at
  # all.
  #
  # `:archive` is slate rather than a second red: filing something away is not
  # the same event as taking it down, and rendering both in `error` made the
  # `expiry_action` split show three names in two colours.
  #
  # `:review_due` is dashed rather than a paler amber: a deadline is a different
  # KIND of thing from a scheduled action, alpha alone put it a hair from
  # `:publish`, and a border STYLE survives being read by someone who cannot
  # separate the hues.
  defp kind_class(:publish), do: "border-warning/40 bg-warning/10"
  defp kind_class(:unpublish), do: "border-error/40 bg-error/10"
  defp kind_class(:archive), do: "border-base-content/35 bg-base-content/10"
  defp kind_class(:expire), do: "border-error/70 bg-error/20 font-medium"
  defp kind_class(:published), do: "border-success/40 bg-success/10"
  defp kind_class(:review_due), do: "border-dashed border-warning/70 bg-warning/10"
  defp kind_class(:task_due), do: "border-info/40 bg-info/10"
  defp kind_class(:release_scheduled), do: "border-primary/50 bg-primary/10 font-medium"
  defp kind_class(:release_published), do: "border-primary/30 bg-primary/5"

  # A release chip goes to the release, not to a content editor — it isn't a
  # content record and has no `{type, id}` editor route.
  defp event_path(%{type: :release, id: id}), do: ~p"/editor/releases/#{id}"
  defp event_path(%{type: type, id: id}), do: ~p"/editor/content/#{type}/#{id}"

  defp today?(date), do: date == Date.utc_today()

  defp reschedulable?(event), do: to_string(event.kind) in @reschedulable

  # The chip's tooltip doubles as its accessible description, so it is also
  # where the keyboard affordance is stated — a `cursor-grab` says nothing to
  # someone who is tabbing.
  defp chip_title(event) do
    base = "#{event.title} — #{event.label} #{kind_label(event.kind)}"

    if reschedulable?(event) do
      base <> " · " <> gettext("arrow keys move it")
    else
      base
    end
  end

  # "Mark reviewed" belongs on a chip that is actually asking for one. A record
  # whose review falls due next month does not need a button saying so on every
  # calendar it appears on.
  defp attestable?(%{kind: :review_due, health: health})
       when health in [:due, :overdue, :expired],
       do: true

  defp attestable?(_event), do: false

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

        <%!-- Dragging a chip is a change with no text for a screen reader to
              read, so the outcome — moved, refused, attested — is announced
              here. `polite`, not `assertive`: it reports what the editor just
              did, and should not cut across what they are reading next. --%>
        <p class="sr-only" role="status" aria-live="polite">{@announcement}</p>
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
    <div class="overflow-x-auto" id="calendar-grid" phx-hook="CalendarDrag">
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
              <.day_chips events={Map.get(@by_day, day, [])} view={@view} day={day} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :events, :list, required: true
  attr :view, :string, required: true
  attr :day, :any, required: true

  defp day_chips(assigns) do
    # Week columns are tall enough to show the day in full; month cells are not,
    # and a cell that grew with its contents would break the grid it is part of.
    {shown, hidden} =
      if assigns.view == "week",
        do: {assigns.events, []},
        else: Enum.split(assigns.events, @month_cell_chips)

    assigns = assigns |> assign(:shown, shown) |> assign(:hidden, hidden)

    ~H"""
    <%!-- Every day is a drop target, including empty ones — a day with nothing
          in it is exactly where you want to drop something. --%>
    <ul class="min-h-6 space-y-1" data-calendar-drop={Date.to_iso8601(@day)}>
      <li :for={ev <- @shown}>
        <.link
          navigate={event_path(ev)}
          class={[
            "block truncate rounded border px-1.5 py-0.5 text-xs hover:opacity-80",
            kind_class(ev.kind),
            reschedulable?(ev) && "cursor-grab active:cursor-grabbing"
          ]}
          title={chip_title(ev)}
          data-reschedulable={reschedulable?(ev) && "true"}
          data-event-id={ev.id}
          data-event-type={ev.type}
          data-event-kind={ev.kind}
          data-event-date={Date.to_iso8601(DateTime.to_date(ev.at))}
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
            <button
              :if={attestable?(ev)}
              type="button"
              phx-click="mark_reviewed"
              phx-value-id={ev.id}
              phx-value-type={ev.type}
              class="btn btn-xs btn-default shrink-0"
            >
              {gettext("Mark reviewed")}
            </button>
          </li>
        </ul>
      </li>
    </ol>
    """
  end
end
