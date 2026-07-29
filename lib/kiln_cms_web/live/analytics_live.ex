defmodule KilnCMSWeb.AnalyticsLive do
  @moduledoc """
  Privacy-first analytics dashboard: total content views, a 7d/30d trend, and
  the most-viewed content. Editor/admin only (`:live_editor_required`). Counts
  come from `KilnCMS.Analytics`; no per-visitor data is collected.

  The trend window lives in the URL (`?range=7`) rather than in socket state, so
  a range is shareable, survives the back button, and is re-derived on reconnect.
  """
  use KilnCMSWeb, :live_view

  import KilnCMSWeb.ChartComponents, only: [bar_chart: 1]

  alias KilnCMS.Analytics
  alias KilnCMS.CMS.ContentTypes

  @top_limit 50
  @ranges [7, 30]
  @default_range 30

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
    rows = Analytics.list_views!(actor: actor, tenant: org, query: [limit: @top_limit])

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:series, series(buckets, since, range))
     |> assign(:total, total_views(actor, org))
     |> assign(:window_total, buckets |> Enum.map(& &1.views) |> Enum.sum())
     |> assign(:rows, rows |> decorate_all(org) |> Enum.map(&add_window(&1, window)))}
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
  # been deleted or whose type was removed.
  defp decorate_all(rows, org) do
    titles =
      rows
      |> Enum.group_by(& &1.content_type)
      |> Enum.flat_map(fn {type, type_rows} ->
        case ContentTypes.get(type, org_id(org)) do
          nil -> []
          ct -> batch_lookup(ct, Enum.map(type_rows, & &1.content_id), org)
        end
      end)
      |> Map.new()

    Enum.map(rows, &decorate(&1, titles))
  end

  # The title-resolution read is tenant-strict (#419) — scope to the dashboard's
  # own org, like every other read on this page.
  defp batch_lookup(ct, ids, org) do
    ct.type
    |> ContentTypes.list!(
      authorize?: false,
      tenant: org,
      query: [filter: [id: [in: ids]], select: [:id, :title, :slug]]
    )
    |> Enum.map(&{&1.id, {&1.title, &1.slug}})
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id), do: id

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
