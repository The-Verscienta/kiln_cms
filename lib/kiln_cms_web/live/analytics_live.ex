defmodule KilnCMSWeb.AnalyticsLive do
  @moduledoc """
  Privacy-first analytics dashboard: total content views, a 7d/30d trend, and
  the most-viewed content. Editor/admin only (`:live_editor_required`). Counts
  come from `KilnCMS.Analytics`; no per-visitor data is collected.

  The trend window lives in the URL (`?range=7`) rather than in socket state, so
  a range is shareable, survives the back button, and is re-derived on reconnect.
  """
  use KilnCMSWeb, :live_view

  import KilnCMSWeb.ChartComponents, only: [bar_chart: 1, category_chart: 1, referrer_bar: 1]

  alias KilnCMS.Analytics
  alias KilnCMS.CMS.ContentTypes

  @top_limit 50
  @ranges [7, 30]
  @default_range 30

  # Render order for the referrer breakdown — shared by the site-wide chart
  # and every per-row bar, so a source's position (and colour, in
  # `ChartComponents`) is consistent everywhere it appears.
  @source_order [:direct, :internal, :search, :social, :other]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Analytics"))
     |> assign(:ranges, @ranges)}
  end

  # The window read, the top-N table and the total are all re-run per range so
  # that patching between 7d and 30d shows consistent numbers.
  @impl true
  def handle_params(params, _uri, socket) do
    actor = socket.assigns.current_user
    # Scope the dashboard to the current site (epic #336).
    org = socket.assigns.current_org
    range = range_from(params)
    since = Date.add(Date.utc_today(), -(range - 1))

    # One windowed read feeds both the chart and the per-row window column.
    # Bounded by the range (unlike the all-time read that audit finding P-M9
    # flagged) and narrowed by the action's select.
    buckets = Analytics.views_since!(since, actor: actor, tenant: org)
    window = window_totals(buckets)

    # Only the rows the table shows — the total is a DB-side SUM, so this no
    # longer loads one counter row per ever-viewed content item.
    rows =
      Analytics.list_views!(actor: actor, tenant: org, query: [limit: @top_limit])
      |> decorate_all(org, actor)
      |> Enum.map(&add_window(&1, window))

    # Referrer attribution (#620) — gated the same way ingestion is (#619): a
    # disabled deployment skips the read entirely, not just the render, so
    # the breakdown is genuinely absent rather than merely hidden.
    referrers_enabled = Analytics.referrers_enabled?()

    {rows, referrer_chart_entries} =
      if referrers_enabled do
        referrer_buckets = Analytics.referrers_since!(since, actor: actor, tenant: org)
        by_content = referrer_by_content(referrer_buckets)

        {Enum.map(rows, &add_referrer_entries(&1, by_content)),
         chart_entries(referrer_totals(referrer_buckets))}
      else
        {rows, []}
      end

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:series, series(buckets, since, range))
     |> assign(:total, total_views(actor, org))
     |> assign(:window_total, buckets |> Enum.map(& &1.views) |> Enum.sum())
     |> assign(:rows, rows)
     |> assign(:referrers_enabled, referrers_enabled)
     |> assign(:referrer_chart_entries, referrer_chart_entries)
     |> assign(:low_count_threshold, Analytics.low_count_threshold())}
  end

  # An unknown or hostile `?range=` falls back to the default rather than
  # raising — this is a bookmarkable URL, not a form submission.
  defp range_from(%{"range" => raw}) do
    case Integer.parse(raw) do
      {n, ""} -> if n in @ranges, do: n, else: @default_range
      _ -> @default_range
    end
  end

  defp range_from(_params), do: @default_range

  # The export links (#618) mirror the dashboard's own current window, so
  # "Export CSV" downloads exactly what's on screen rather than a separate
  # default.
  defp export_href(:csv, range), do: ~p"/editor/analytics/export.csv?#{export_query(range)}"
  defp export_href(:json, range), do: ~p"/editor/analytics/export.json?#{export_query(range)}"

  defp export_query(range) do
    to = Date.utc_today()
    from = Date.add(to, -(range - 1))
    [from: Date.to_iso8601(from), to: Date.to_iso8601(to)]
  end

  # A continuous series, oldest → newest, with days that saw no views filled in
  # as zero. Without the fill the chart would close the gaps and misstate the
  # trend. Buckets are summed across all content for the site-wide line.
  defp series(buckets, since, range) do
    by_day =
      Enum.reduce(buckets, %{}, fn bucket, acc ->
        Map.update(acc, bucket.day, bucket.views, &(&1 + bucket.views))
      end)

    for offset <- 0..(range - 1) do
      day = Date.add(since, offset)
      %{day: day, views: Map.get(by_day, day, 0)}
    end
  end

  # Views per content item within the window, for the table's range column.
  defp window_totals(buckets) do
    Enum.reduce(buckets, %{}, fn bucket, acc ->
      Map.update(
        acc,
        {bucket.content_type, bucket.content_id},
        bucket.views,
        &(&1 + bucket.views)
      )
    end)
  end

  defp add_window(row, window),
    do: Map.put(row, :window_views, Map.get(window, {row.type, row.id}, 0))

  # Site-wide hits per source within the window, for the breakdown chart.
  defp referrer_totals(buckets) do
    Enum.reduce(buckets, %{}, fn bucket, acc ->
      Map.update(acc, bucket.source, bucket.hits, &(&1 + bucket.hits))
    end)
  end

  # Per-content-item hits per source within the window, for each row's
  # breakdown bar.
  defp referrer_by_content(buckets) do
    Enum.reduce(buckets, %{}, fn bucket, acc ->
      Map.update(
        acc,
        {bucket.content_type, bucket.content_id},
        %{bucket.source => bucket.hits},
        &Map.update(&1, bucket.source, bucket.hits, fn hits -> hits + bucket.hits end)
      )
    end)
  end

  defp add_referrer_entries(row, by_content) do
    sources = Map.get(by_content, {row.type, row.id}, %{})
    Map.put(row, :referrer_entries, chart_entries(sources))
  end

  # One entry per known source, in a fixed order, whether or not this window
  # saw any hits for it — a zero-hit source still needs a bar (height 0) and
  # a row in the sr-only breakdown, or its absence would read as "we don't
  # track this category" rather than "nobody arrived this way".
  #
  # Complementary suppression (#620 review): every classified arrival writes
  # exactly one referrer hit alongside its view (`ViewTracking.record/4`), so
  # the five categories here sum to the row's own exact view total shown
  # beside them. If exactly one category is naturally below the threshold,
  # its value is fully determined by subtracting the other four EXACT values
  # from that total — publishing "< n" next to four exact numbers doesn't
  # hide anything. When that happens, a second category (the smallest
  # nonzero exact one) is suppressed too, so the equation has two unknowns
  # instead of one. Two or more naturally-suppressed categories need no help:
  # their individual values are already underdetermined by the total alone.
  defp chart_entries(totals) do
    threshold = Analytics.low_count_threshold()
    raw = Enum.map(@source_order, fn source -> {source, Map.get(totals, source, 0)} end)
    naturally_suppressed = for {source, hits} <- raw, hits > 0 and hits < threshold, do: source

    forced_source =
      case naturally_suppressed do
        [only] -> complementary_partner(raw, only)
        _ -> nil
      end

    Enum.map(raw, fn {source, hits} -> chart_entry(source, hits, source == forced_source) end)
  end

  # The smallest not-already-suppressed category — suppressing it too means
  # the one naturally-low category can no longer be pinned down by
  # subtracting the other three "exact" values from the row's total.
  #
  # Deliberately includes zero-hit categories as candidates: if every OTHER
  # category is a genuine zero, the naturally-suppressed one is exactly
  # `total − 0 − 0 − 0 − 0`, the single most recoverable case there is.
  # Excluding zeros from the candidate pool (as an earlier version of this
  # function did) would leave exactly that case unprotected. Turning an
  # honest "0" into "hidden" costs real information, but there are always
  # four other categories to choose from, so this never returns `nil`.
  defp complementary_partner(raw, already_suppressed) do
    {source, _hits} =
      raw
      |> Enum.reject(fn {source, _hits} -> source == already_suppressed end)
      |> Enum.min_by(fn {_source, hits} -> hits end)

    source
  end

  # `display` is the only number a person ever sees. A naturally low count
  # renders as `Analytics.suppress_low_count/1`'s "< n"; a count forced into
  # suppression for complementary reasons (see `chart_entries/1`) is NOT
  # labelled "< n" — its real value can be at or above the threshold, so that
  # would be false — it renders as a plain "hidden" instead.
  #
  # `bar_value` drives the bar's height/width and is deliberately never the
  # raw hit count for a suppressed entry, natural or forced: comparing two
  # suppressed bars' sizes would leak exactly the magnitude the label just
  # hid. Every suppressed, nonzero entry clamps to the same fixed value — the
  # largest a naturally-suppressed count could honestly be — so bars stay
  # roughly proportionate without ever distinguishing one suppressed count
  # from another. A true zero still renders as a flat bar: there is nothing
  # to describe, so nothing to hide.
  defp chart_entry(source, hits, forced_suppress?) do
    natural = Analytics.suppress_low_count(hits)
    threshold = Analytics.low_count_threshold()

    display =
      cond do
        is_binary(natural) -> natural
        forced_suppress? -> gettext("hidden")
        true -> natural
      end

    bar_value = if is_binary(natural) or forced_suppress?, do: threshold - 1, else: hits

    %{source: source, label: source_label(source), display: display, bar_value: bar_value}
  end

  defp source_label(:direct), do: gettext("Direct")
  defp source_label(:internal), do: gettext("Internal")
  defp source_label(:search), do: gettext("Search")
  defp source_label(:social), do: gettext("Social")
  defp source_label(:other), do: gettext("Other")

  # SUM over zero rows yields nil (despite Ash.sum's number() typing, which is
  # why this is a pattern match rather than `|| 0` — dialyzer rejects the
  # latter as an impossible guard).
  defp total_views(actor, org) do
    case Ash.sum(KilnCMS.Analytics.ContentView, :views, actor: actor, tenant: org) do
      {:ok, total} when is_integer(total) -> total
      _ -> 0
    end
  end

  # Resolve counter rows to display data with one id-batched query per content
  # type (instead of a point query per row), tolerating content that has since
  # been deleted or whose type was removed. Shared with the analytics export
  # (#618) via `KilnCMS.Analytics.Titles`, so both apply the same fallback.
  defp decorate_all(rows, org, actor) do
    titles = Analytics.Titles.resolve(rows, org, actor)
    Enum.map(rows, &decorate(&1, titles))
  end

  defp decorate(row, titles) do
    case ContentTypes.get(row.content_type) do
      nil ->
        %{
          id: row.content_id,
          title: "(unknown type: #{row.content_type})",
          type: row.content_type,
          href: nil,
          views: row.views,
          last: row.last_viewed_at
        }

      ct ->
        {title, slug} = Map.get(titles, row.content_id, {"(deleted)", nil})

        %{
          id: row.content_id,
          title: title,
          type: row.content_type,
          href: editor_href(ct, row.content_id),
          public: public_href(ct, slug),
          views: row.views,
          last: row.last_viewed_at
        }
    end
  end

  defp editor_href(ct, id), do: ~p"/editor/content/#{ct.type}/#{id}"

  defp public_href(_ct, nil), do: nil
  defp public_href(ct, slug), do: "#{ContentTypes.public_prefix(ct)}/#{slug}"

  defp humanize(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:analytics}
    >
      <div class="space-y-6">
        <div>
          <.link navigate={~p"/editor"} class="text-sm text-base-content/60 hover:underline">
            &larr; {gettext("All content")}
          </.link>
          <h1 class="mt-1 text-2xl font-semibold">{gettext("Analytics")}</h1>
          <p class="text-sm text-base-content/60">
            {gettext("Privacy-first content views — aggregate counts only, no visitor tracking.")}
          </p>
          <div class="mt-3 flex gap-2">
            <a href={export_href(:json, @range)} class="btn btn-sm btn-default" download>
              <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export (JSON)")}
            </a>
            <a href={export_href(:csv, @range)} class="btn btn-sm btn-default" download>
              <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export (CSV)")}
            </a>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="card card-pad">
            <p class="text-xs uppercase tracking-wide text-base-content/70">
              {gettext("Total views")}
            </p>
            <p class="mt-1 text-3xl font-semibold tabular-nums">{@total}</p>
            <p class="text-xs text-base-content/60">{gettext("All time")}</p>
          </div>
          <div class="card card-pad">
            <p class="text-xs uppercase tracking-wide text-base-content/70">
              {gettext("Views in range")}
            </p>
            <p class="mt-1 text-3xl font-semibold tabular-nums">{@window_total}</p>
            <p class="text-xs text-base-content/60">
              {ngettext("Last %{count} day", "Last %{count} days", @range, count: @range)}
            </p>
          </div>
        </div>

        <div>
          <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-lg font-medium">{gettext("Views over time")}</h2>
            <div class="tabs" role="tablist" aria-label={gettext("Trend range")}>
              <.link
                :for={r <- @ranges}
                patch={~p"/editor/analytics?#{[range: r]}"}
                role="tab"
                aria-selected={to_string(@range == r)}
                class="tab"
              >
                {ngettext("%{count} day", "%{count} days", r, count: r)}
              </.link>
            </div>
          </div>

          <p :if={@total == 0} class="text-sm text-base-content/60">
            {gettext("No views recorded yet.")}
          </p>
          <p :if={@total > 0 and @window_total == 0} class="text-sm text-base-content/60">
            {ngettext(
              "No views in the last %{count} day.",
              "No views in the last %{count} days.",
              @range,
              count: @range
            )}
          </p>

          <.bar_chart
            :if={@window_total > 0}
            series={@series}
            label={
              ngettext(
                "Content views per day for the last %{count} day",
                "Content views per day for the last %{count} days",
                @range,
                count: @range
              )
            }
          />

          <p :if={@window_total > 0} class="mt-2 text-xs text-base-content/60">
            {gettext(
              "Daily buckets use UTC calendar days; today's bar is still filling. History starts when this feature was deployed."
            )}
          </p>
        </div>

        <%!-- No separate empty state: the "Views over time" section above
              already says "no views in the last N days" when @window_total is
              0, and every referrer hit is written alongside a view, so a
              second empty message here would only repeat it. --%>
        <div :if={@referrers_enabled and @window_total > 0}>
          <h2 class="mb-1 text-lg font-medium">{gettext("Where readers came from")}</h2>
          <p class="mb-3 text-xs text-base-content/60">
            {gettext(
              "\"Direct\" is a catch-all: it includes a referrer the visitor's browser or the referring site chose not to send, not just a typed-in URL."
            )}
          </p>

          <.category_chart
            entries={@referrer_chart_entries}
            label={gettext("Referrer sources for the selected range")}
          />

          <p class="mt-2 text-xs text-base-content/60">
            {gettext(
              "Counts below %{n} show as \"< %{n}\" rather than an exact number — a very small count can describe a single visitor's arrival.",
              n: @low_count_threshold
            )}
          </p>
        </div>

        <div>
          <h2 class="mb-3 text-lg font-medium">{gettext("Most viewed")}</h2>
          <p :if={@rows == []} class="text-sm text-base-content/60">
            {gettext("No views recorded yet.")}
          </p>

          <table :if={@rows != []} class="table">
            <thead>
              <tr>
                <th scope="col">{gettext("Content")}</th>
                <th scope="col">{gettext("Type")}</th>
                <th scope="col" class="text-right">
                  {ngettext("Views (%{count}d)", "Views (%{count}d)", @range, count: @range)}
                </th>
                <th scope="col" class="text-right">{gettext("Views (all time)")}</th>
                <th :if={@referrers_enabled} scope="col">{gettext("Referrers")}</th>
                <th scope="col" class="text-right">{gettext("Last viewed")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td>
                  <.link :if={row.href} navigate={row.href} class="font-medium hover:underline">
                    {row.title}
                  </.link>
                  <span :if={!row.href} class="font-medium">{row.title}</span>
                  <a
                    :if={row[:public]}
                    href={row.public}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="ml-2 text-xs text-primary hover:underline"
                  >
                    view &nearr; <span class="sr-only">{gettext("(opens in a new tab)")}</span>
                  </a>
                </td>
                <td class="capitalize text-base-content/70">{row.type}</td>
                <td class="text-right tabular-nums">{row.window_views}</td>
                <td class="text-right font-medium tabular-nums">{row.views}</td>
                <td :if={@referrers_enabled} class="w-32">
                  <.referrer_bar entries={row.referrer_entries} label={gettext("Referrer breakdown")} />
                </td>
                <td class="text-right text-base-content/60">
                  <time
                    :if={row.last}
                    id={"last-viewed-#{row.type}-#{row.id}"}
                    phx-hook="LocalTime"
                    datetime={DateTime.to_iso8601(row.last)}
                  >{humanize(row.last)} UTC</time>
                  <span :if={!row.last}>—</span>
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
