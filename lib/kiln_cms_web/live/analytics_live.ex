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

    {:ok,
     socket
     |> assign(:total, Enum.sum_by(rows, & &1.views))
     |> assign(:rows, rows |> Enum.take(50) |> Enum.map(&decorate/1))}
  end

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
    <Layouts.app flash={@flash} current_user={@current_user}>
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

        <div class="rounded-lg border border-base-content/10 p-4">
          <p class="text-xs uppercase tracking-wide text-base-content/50">{gettext("Total views")}</p>
          <p class="mt-1 text-3xl font-semibold">{@total}</p>
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
                    rel="noopener noreferrer"
                    class="ml-2 text-xs text-primary hover:underline"
                  >
                    view &nearr; <span class="sr-only">{gettext("(opens in a new tab)")}</span>
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
