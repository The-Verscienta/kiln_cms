defmodule KilnCMSWeb.GovernanceLive do
  @moduledoc """
  Compliance & governance dashboard (`/editor/governance`) — the visible home for
  the compliance cluster (#352). Per content item it surfaces the editorial
  version timeline (PaperTrail), the linked consents (#356), point-in-time access
  (#338), and a JSON export of the trail. Admin-only.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Governance

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role == :admin do
      {:ok, assign(socket, :page_title, gettext("Governance"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You need admin access to view that page."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:trail, nil)
    |> assign(:content, Governance.content_index(socket.assigns.current_org.id))
  end

  defp apply_action(socket, :show, %{"type" => type, "id" => id}) do
    case Governance.trail(type, id, socket.assigns.current_org.id) do
      nil ->
        socket
        |> put_flash(:error, gettext("That content couldn't be found."))
        |> push_navigate(to: ~p"/editor/governance")

      trail ->
        assign(socket, :trail, trail)
    end
  end

  # Point-in-time delivery URL (#338) for one publish instant.
  defp point_in_time_url(item, %DateTime{} = at) do
    "/api/content/#{item.type}/#{item.slug}?as_of=#{DateTime.to_iso8601(at)}"
  end

  defp when_str(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      active={:governance}
    >
      <.index :if={is_nil(@trail)} content={@content} />
      <.detail :if={@trail} trail={@trail} />
    </Layouts.console>
    """
  end

  attr :content, :list, required: true

  defp index(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Governance")}</h1>
        <p class="text-sm text-base-content/70">
          {gettext("Audit trail, consent records, and point-in-time history for your content.")}
        </p>
      </div>

      <p :if={@content == []} class="text-sm text-base-content/60">{gettext("No content yet.")}</p>

      <ul :if={@content != []} class="card divide-y divide-base-content/10 overflow-hidden">
        <li :for={item <- @content} class="flex items-center justify-between p-3">
          <div class="min-w-0">
            <.link
              navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
              class="text-sm font-medium hover:underline"
            >
              {item.title}
            </.link>
            <span class="ml-2 text-xs text-base-content/50">{item.type} · {item.state}</span>
          </div>
          <.link
            navigate={~p"/editor/governance/#{item.type}/#{item.id}"}
            class="btn btn-sm btn-default"
          >
            {gettext("Trail")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :trail, :map, required: true

  defp detail(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.link navigate={~p"/editor/governance"} class="text-sm text-base-content/60 hover:underline">
          &larr; {gettext("All content")}
        </.link>
        <h1 class="mt-1 text-2xl font-semibold">{@trail.item.title}</h1>
        <p class="text-sm text-base-content/60">
          {@trail.item.type} · {@trail.item.state}
        </p>
        <a
          href={~p"/editor/governance/#{@trail.item.type}/#{@trail.item.id}/export.json"}
          class="btn btn-sm btn-default mt-3"
          download
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export trail (JSON)")}
        </a>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Consent records")} ({length(@trail.consents)})</h2>
        <p :if={@trail.consents == []} class="text-sm text-base-content/60">
          {gettext("No consent recorded for this content.")}
        </p>
        <ul :if={@trail.consents != []} class="card divide-y divide-base-content/10 overflow-hidden">
          <li :for={c <- @trail.consents} class="p-3 text-sm">
            <span class="rounded bg-success/15 px-1.5 py-0.5 text-xs font-medium text-success">
              {c.kind}
            </span>
            <span :if={c.grantor} class="ml-2">{gettext("by")} {c.grantor}</span>
            <span :if={c.granted_at} class="ml-2 text-base-content/60">{when_str(c.granted_at)}</span>
            <code :if={c.reference} class="ml-2 text-xs text-base-content/60">{c.reference}</code>
          </li>
        </ul>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">{gettext("Version timeline")}</h2>
        <p :if={@trail.timeline == []} class="text-sm text-base-content/60">
          {gettext("No versions recorded.")}
        </p>
        <div :if={@trail.timeline != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("Action")}</th>
                <th>{gettext("Changed")}</th>
                <th>{gettext("Point in time")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @trail.timeline}>
                <td class="whitespace-nowrap text-base-content/70">{when_str(e.at)}</td>
                <td>
                  <span class={[
                    "rounded px-1.5 py-0.5 text-xs font-medium",
                    e.publish? && "bg-primary/15 text-primary",
                    !e.publish? && "bg-base-200 text-base-content/70"
                  ]}>
                    {e.action}
                  </span>
                </td>
                <td class="max-w-64 truncate text-xs text-base-content/60">
                  {Enum.join(e.changed, ", ")}
                </td>
                <td>
                  <a
                    :if={e.publish?}
                    href={point_in_time_url(@trail.item, e.at)}
                    class="text-xs text-primary hover:underline"
                    target="_blank"
                    rel="noopener"
                  >
                    {gettext("View as of then")}
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
