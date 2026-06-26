defmodule KilnCMSWeb.AnalyticsLive do
  @moduledoc """
  Privacy-first analytics dashboard: total content views and the most-viewed
  content. Editor/admin only (`:live_editor_required`). Counts come from
  `KilnCMS.Analytics`; no per-visitor data is collected.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Analytics
  alias KilnCMS.CMS.ContentTypes

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    rows = Analytics.list_views!(actor: actor)

    today = Date.utc_today()
    daily = Analytics.views_since!(Date.add(today, -29), actor: actor)
    series = build_series(daily, today)

    {:ok,
     socket
     |> assign(:total, Enum.sum_by(rows, & &1.views))
     |> assign(:series, series)
     |> assign(:series_max, series |> Enum.map(& &1.views) |> Enum.max(fn -> 0 end))
     |> assign(:total_7d, sum_last(series, 7))
     |> assign(:total_30d, sum_last(series, 30))
     |> assign(:rows, rows |> Enum.take(50) |> Enum.map(&decorate/1))}
  end

  # A continuous 30-day series (oldest → newest), filling days with no views as
  # zero so the trend chart has no gaps. Daily rows are summed across all
  # content for the site-wide trend.
  defp build_series(daily, today) do
    by_day =
      daily
      |> Enum.group_by(& &1.day)
      |> Map.new(fn {day, rows} -> {day, Enum.sum_by(rows, & &1.views)} end)

    for offset <- 29..0//-1 do
      day = Date.add(today, -offset)
      %{day: day, views: Map.get(by_day, day, 0)}
    end
  end

  defp sum_last(series, n), do: series |> Enum.take(-n) |> Enum.sum_by(& &1.views)

  # Bar height as a percentage of the busiest day (min 2% so non-zero days are
  # visible). Zero-view days render flat.
  defp bar_pct(_views, 0), do: 0
  defp bar_pct(0, _max), do: 0
  defp bar_pct(views, max), do: max(round(views / max * 100), 2)

  # Resolve a counter row to display data, tolerating content that has since
  # been deleted or whose type was removed.
  defp decorate(row) do
    case ContentTypes.get(row.content_type) do
      nil ->
        %{
          title: "(unknown type: #{row.content_type})",
          type: row.content_type,
          href: nil,
          views: row.views,
          last: row.last_viewed_at
        }

      ct ->
        {title, slug} = lookup(ct, row.content_id)

        %{
          title: title,
          type: row.content_type,
          href: editor_href(ct, row.content_id),
          public: public_href(ct, slug),
          views: row.views,
          last: row.last_viewed_at
        }
    end
  end

  defp lookup(ct, id) do
    case ContentTypes.get_record(ct.type, id, authorize?: false) do
      {:ok, record} -> {record.title, record.slug}
      _ -> {"(deleted)", nil}
    end
  end

  defp editor_href(ct, id), do: ~p"/editor/content/#{ct.type}/#{id}"

  defp public_href(_ct, nil), do: nil
  defp public_href(ct, slug), do: "#{ContentTypes.public_prefix(ct)}/#{slug}"

  defp humanize(nil), do: "—"
  defp humanize(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div class="rounded-lg border border-base-content/10 p-4">
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Total views")}
            </p>
            <p class="mt-1 text-3xl font-semibold">{@total}</p>
          </div>
          <div class="rounded-lg border border-base-content/10 p-4">
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Last 7 days")}
            </p>
            <p class="mt-1 text-3xl font-semibold">{@total_7d}</p>
          </div>
          <div class="rounded-lg border border-base-content/10 p-4">
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Last 30 days")}
            </p>
            <p class="mt-1 text-3xl font-semibold">{@total_30d}</p>
          </div>
        </div>

        <div>
          <h2 class="mb-3 text-lg font-medium">{gettext("Views over the last 30 days")}</h2>
          <p :if={@series_max == 0} class="text-sm text-base-content/60">
            {gettext("No views recorded in this window yet.")}
          </p>
          <div
            :if={@series_max > 0}
            class="flex h-32 items-end gap-0.5"
            role="img"
            aria-label={gettext("Daily content views for the last 30 days")}
          >
            <div
              :for={point <- @series}
              class="flex-1 rounded-t bg-primary/70 hover:bg-primary"
              style={"height: #{bar_pct(point.views, @series_max)}%"}
              title={"#{Calendar.strftime(point.day, "%Y-%m-%d")}: #{point.views}"}
            >
            </div>
          </div>
        </div>

        <div>
          <h2 class="mb-3 text-lg font-medium">{gettext("Most viewed")}</h2>
          <p :if={@rows == []} class="text-sm text-base-content/60">
            {gettext("No views recorded yet.")}
          </p>

          <table :if={@rows != []} class="w-full text-sm">
            <thead class="text-left text-xs uppercase tracking-wide text-base-content/50">
              <tr class="border-b border-base-content/10">
                <th class="py-2">{gettext("Content")}</th>
                <th class="py-2">{gettext("Type")}</th>
                <th class="py-2 text-right">{gettext("Views")}</th>
                <th class="py-2 text-right">{gettext("Last viewed")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} class="border-b border-base-content/5">
                <td class="py-2">
                  <.link :if={row.href} navigate={row.href} class="font-medium hover:underline">
                    {row.title}
                  </.link>
                  <span :if={!row.href} class="font-medium">{row.title}</span>
                  <a
                    :if={row[:public]}
                    href={row.public}
                    target="_blank"
                    class="ml-2 text-xs text-primary hover:underline"
                  >
                    view &nearr;
                  </a>
                </td>
                <td class="py-2 capitalize text-base-content/70">{row.type}</td>
                <td class="py-2 text-right font-medium">{row.views}</td>
                <td class="py-2 text-right text-base-content/60">{humanize(row.last)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
