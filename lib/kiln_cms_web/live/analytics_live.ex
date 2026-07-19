defmodule KilnCMSWeb.AnalyticsLive do
  @moduledoc """
  Privacy-first analytics dashboard: total content views and the most-viewed
  content. Editor/admin only (`:live_editor_required`). Counts come from
  `KilnCMS.Analytics`; no per-visitor data is collected.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Analytics
  alias KilnCMS.CMS.ContentTypes

  @top_limit 50

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    # Scope the dashboard to the current site (epic #336).
    org = socket.assigns.current_org
    # Only the rows the table shows — the total is a DB-side SUM, so mount no
    # longer loads one counter row per ever-viewed content item.
    rows = Analytics.list_views!(actor: actor, tenant: org, query: [limit: @top_limit])

    {:ok,
     socket
     |> assign(:page_title, gettext("Analytics"))
     |> assign(:total, total_views(actor, org))
     |> assign(:rows, decorate_all(rows))}
  end

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
  defp decorate_all(rows) do
    titles =
      rows
      |> Enum.group_by(& &1.content_type)
      |> Enum.flat_map(fn {type, type_rows} ->
        case ContentTypes.get(type) do
          nil -> []
          ct -> batch_lookup(ct, Enum.map(type_rows, & &1.content_id))
        end
      end)
      |> Map.new()

    Enum.map(rows, &decorate(&1, titles))
  end

  defp batch_lookup(ct, ids) do
    ct.type
    |> ContentTypes.list!(
      authorize?: false,
      query: [filter: [id: [in: ids]], select: [:id, :title, :slug]]
    )
    |> Enum.map(&{&1.id, {&1.title, &1.slug}})
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

        <div class="card card-pad">
          <p class="text-xs uppercase tracking-wide text-base-content/70">{gettext("Total views")}</p>
          <p class="mt-1 text-3xl font-semibold">{@total}</p>
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
                <th scope="col" class="text-right">{gettext("Views")}</th>
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
                <td class="text-right font-medium">{row.views}</td>
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
