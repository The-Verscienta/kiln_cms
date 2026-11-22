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
  alias KilnCMS.Analytics.FunnelReport
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Search.Related
  alias KilnCMSWeb.Params

  @top_limit 50
  @gap_limit 20
  @ranges [7, 30]
  @default_range 30

  # Render order for the referrer breakdown — shared by the site-wide chart
  # and every per-row bar, so a source's position (and colour, in
  # `ChartComponents`) is consistent everywhere it appears.

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

    # Completed days only, and every figure on this page derived from the
    # per-day breakdowns the export publishes (#2989) — see
    # `Analytics.derive_referrer_group/1` for why a span is never suppressed
    # from its own raw sum.
    {rows, referrer_chart_entries} =
      if referrers_enabled do
        cells =
          since
          |> Analytics.referrers_since!(actor: actor, tenant: org)
          |> Analytics.published_referrer_cells()

        by_content =
          Enum.group_by(cells, fn {{_day, type, id}, _} -> {type, id} end, &elem(&1, 1))

        {Enum.map(rows, &add_referrer_entries(&1, by_content)),
         chart_entries(Enum.map(cells, &elem(&1, 1)))}
      else
        {rows, []}
      end

    # The site chart is derived from every cell any row's bar is, so a hidden
    # category in any bar is hidden in the chart too (#2990).
    referrers_hidden? = Enum.any?(referrer_chart_entries, & &1.hidden?)

    # Funnel reports (#622) — derived from the same bucket table as the rest
    # of the page, never a separate counter. Each funnel is independently
    # small (a handful of admin-authored steps), so reporting on every
    # *active* funnel costs one targeted read per distinct step content type,
    # not a scan. Inactive funnels are omitted, same as the dashboard would
    # hide any other disabled feature.
    funnels =
      Analytics.list_funnels!(
        actor: actor,
        tenant: org,
        query: [filter: [active: true], sort: [inserted_at: :asc]]
      )

    funnel_reports =
      Enum.map(funnels, &{&1, FunnelReport.report(&1, since, Date.utc_today(), org, actor)})

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:series, series(buckets, since, range))
     |> assign(:total, total_views(actor, org))
     |> assign(:window_total, buckets |> Enum.map(& &1.views) |> Enum.sum())
     |> assign(:rows, rows)
     |> assign(:referrers_enabled, referrers_enabled)
     |> assign(:referrer_chart_entries, referrer_chart_entries)
     |> assign(:referrers_hidden?, referrers_hidden?)
     |> assign(:low_count_threshold, Analytics.low_count_threshold())
     |> assign(:funnel_reports, funnel_reports)
     # Content gaps (#339): what on-site searchers asked for and got nothing
     # for. Deliberately *not* windowed by `?range=` — a gap is a standing
     # absence, and the counter table keeps a running total per query rather
     # than per-day buckets, so there is no honest way to slice it by date
     # anyway. Its own retention window (`SearchQuery`'s nightly purge) is what
     # keeps it from accumulating forever.
     |> assign(:content_gaps, Related.content_gaps(org, actor: actor, limit: @gap_limit))}
  end

  # An unknown or hostile `?range=` falls back to the default rather than
  # raising — this is a bookmarkable URL, not a form submission.
  #
  # Read through `KilnCMSWeb.Params` (#764), because the client picks the
  # parameter's *shape* as well as its value: `?range[]=7` decodes to a LIST,
  # which the previous `Integer.parse/1` had no clause for and raised on. The
  # old comment covered a hostile *string* only, and the difference is a link
  # someone can be sent.
  defp range_from(params) do
    range = Params.integer(params, "range", @default_range, 0..1_000_000)

    if range in @ranges, do: range, else: @default_range
  end

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

  # An item with no referrer buckets in the window has no cells, which derives
  # to a zero in every category.
  defp add_referrer_entries(row, by_content) do
    cells = Map.get(by_content, {row.type, row.id}, [])
    Map.put(row, :referrer_entries, chart_entries(cells))
  end

  # Each cell was decided by `Analytics.suppress_referrer_group/1` — shared
  # with the export (#777) — and the span is derived from those decisions
  # (#2989). This is only the rendering.
  defp chart_entries(cells) do
    cells
    |> Analytics.derive_referrer_group()
    |> Enum.map(fn {source, display} -> chart_entry(source, display) end)
  end

  # `display` is the only number a person ever sees, and it arrives already
  # decided: the sum of the per-day displays, or `"hidden"`.
  #
  # `bar_value` drives the bar's height/width and is deliberately never a raw
  # hit count for a hidden entry: comparing two hidden bars' sizes would leak
  # exactly the magnitude the label just hid. Every hidden entry clamps to the
  # same fixed value, the largest a naturally-suppressed count could honestly
  # be, so bars stay roughly proportionate without ever distinguishing one
  # hidden count from another. A true zero still renders as a flat bar: there
  # is nothing to describe, so nothing to hide.
  defp chart_entry(source, display) do
    hidden? = is_binary(display)

    %{
      source: source,
      label: source_label(source),
      # The shared decision returns the untranslated `"hidden"` sentinel — it
      # is a value an export writes into a file as well as a word a person
      # reads, so the translation belongs at the render, not in the algorithm.
      display: if(hidden?, do: gettext("hidden"), else: display),
      bar_value: if(hidden?, do: Analytics.low_count_threshold() - 1, else: display),
      hidden?: hidden?
    }
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

  # No denominator (first step, or a zero-view previous step) and a
  # suppressed count both render as an em dash — neither is "0%", which
  # would misreport an unmeasurable ratio as a real, measured drop.
  defp ratio_label(nil), do: "—"
  defp ratio_label(ratio), do: "#{ratio}%"

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
          <Layouts.console_crumb
            current_user={@current_user}
            current_org={@current_org}
            active={:analytics}
          />
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
              "Referrer counts cover completed UTC days only, so today's arrivals appear tomorrow."
            )}
          </p>
          <%!-- #2990: without this, a breakdown that is hidden whole reads
                like missing data. Shown only when something is hidden. --%>
          <p
            :if={@referrers_hidden?}
            id="referrers-hidden-note"
            class="mt-1 text-xs text-base-content/70"
          >
            {gettext(
              "\"hidden\" means that on at least one day in this range, too few readers arrived that way to show the day's count safely (fewer than %{n}, or a count that could be deduced from one that small). A total that included that day could be compared with the daily figures in the export to recover it, so the total is hidden too.",
              n: @low_count_threshold
            )}
          </p>
        </div>

        <div :if={@funnel_reports != []} class="space-y-6">
          <div>
            <h2 class="mb-1 text-lg font-medium">{gettext("Funnels")}</h2>
            <p class="text-xs text-base-content/60">
              {gettext(
                "Steps are counted independently — this is not a per-visitor conversion rate. A later step's count includes traffic that never saw an earlier one, so a ratio can read above 100%."
              )}
            </p>
          </div>

          <div :for={{funnel, steps} <- @funnel_reports} class="card card-pad">
            <h3 class="mb-3 font-medium">{funnel.name}</h3>

            <table class="table">
              <thead>
                <tr>
                  <th scope="col">{gettext("Step")}</th>
                  <th scope="col" class="text-right">
                    {ngettext("Views (%{count}d)", "Views (%{count}d)", @range, count: @range)}
                  </th>
                  <th scope="col" class="text-right">{gettext("vs. previous step")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{step, index} <- Enum.with_index(steps, 1)}>
                  <td>
                    <span class="text-base-content/50">{index}.</span> {step.title}
                  </td>
                  <td class="text-right tabular-nums">{step.display}</td>
                  <td class="text-right tabular-nums">{ratio_label(step.ratio)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Content gaps (#339): the zero-result half of the search log. The
              "most viewed" table says what the site has that works; this says
              what it doesn't have at all, which is the only thing on this page
              that no view counter can ever show. --%>
        <div :if={@content_gaps != []}>
          <h2 class="mb-1 text-lg font-medium">{gettext("Content gaps")}</h2>
          <p class="mb-3 text-xs text-base-content/60">
            {gettext(
              "On-site searches that returned nothing. Each is a reader who looked for something this site doesn't cover."
            )}
          </p>

          <table class="table">
            <thead>
              <tr>
                <th scope="col">{gettext("Search")}</th>
                <th scope="col" class="text-right">{gettext("Times searched")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={gap <- @content_gaps}>
                <%!-- A recorded search term is visitor input echoed to an
                      editor. HEEx escapes it, and the width cap keeps a
                      pathological query from stretching the table. --%>
                <td class="max-w-md truncate">{gap.query}</td>
                <td class="text-right font-medium tabular-nums">{gap.searches}</td>
              </tr>
            </tbody>
          </table>
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
                    aria-label={
                      gettext("View %{title} on the site (opens in a new tab)", title: row.title)
                    }
                    class="ml-2 text-xs text-primary-ink hover:underline"
                  >
                    {gettext("view")} <span aria-hidden="true">&nearr;</span>
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
