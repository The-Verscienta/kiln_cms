defmodule KilnCMSWeb.InstanceSecurityLogLive do
  @moduledoc """
  The instance security log (#2541): events about the installation as a whole
  rather than one site, such as a platform admin canceling a backup. Newest
  first, filterable by event type, actor (an email address) and a date range,
  with a keyset "load more" and a CSV download of the same filters.

  **Platform admins only.** The `:admin_routes` live session's
  `:live_admin_required` hook admits any admin of the current site, so the page
  refuses everyone else itself at mount (as `KilnCMSWeb.SystemLive` does), and
  every client-bound event re-checks `LiveUserAuth.platform_admin?/1`, because
  the socket outlives the mount-time check and a temporary platform grant
  expires. The read itself runs as the signed-in user with no tenant, so
  `KilnCMS.Security.InstanceEvent`'s `PlatformAdmin` policy decides every row:
  the default site's admins, who need not be platform admins, see none of it.

  Filters live in the URL (`?type=&actor=&from=&to=`), read by
  `KilnCMSWeb.SecurityLog` with the `:instance` scope. The retention window is
  the deployment's (`KILN_INSTANCE_SECURITY_LOG_RETENTION_DAYS`), shown here
  and changed only in the environment.

  Everything in a row is escaped by HEEx.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Security
  alias KilnCMSWeb.SecurityLog

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if platform_admin?(socket) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Instance security log"))
       |> assign(:filters, %{})
       |> assign(:events, [])
       |> assign(:page, nil)
       |> assign(:unknown_actor?, false)
       |> assign(:retention_days, Security.instance_retention_days())}
    else
      # Not redundant: the live session admits any ADMIN of this site, and this
      # log needs a PLATFORM admin.
      {:ok, push_navigate(socket, to: KilnCMSWeb.AccessDenied.path(:platform))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if platform_admin?(socket) do
      filters = SecurityLog.parse(params, :instance)

      {:noreply,
       socket
       |> assign(:filters, filters)
       |> assign(:filter_form, to_form(filter_params(filters), as: :filters))
       |> load_first_page()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) when is_map(params) do
    if platform_admin?(socket) do
      {:noreply,
       push_patch(socket,
         to: ~p"/editor/instance-security-log?#{SecurityLog.parse(params, :instance)}"
       )}
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{page: %Ash.Page.Keyset{} = page}} = socket) do
    if platform_admin?(socket) do
      case Ash.page(page, :next) do
        {:ok, next} ->
          {:noreply,
           socket |> assign(:page, next) |> assign(:events, socket.assigns.events ++ next.results)}

        {:error, _error} ->
          {:noreply, put_flash(socket, :error, gettext("The log could not be loaded."))}
      end
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  defp platform_admin?(socket), do: KilnCMSWeb.LiveUserAuth.platform_admin?(socket)

  defp load_first_page(socket) do
    %{current_user: user, filters: filters} = socket.assigns

    with {:ok, args} <- SecurityLog.arguments(filters, user, :instance),
         {:ok, %Ash.Page.Keyset{} = page} <-
           Security.list_instance_events(args,
             actor: user,
             page: [limit: @page_size, count: false],
             authorize_with: :error
           ) do
      socket
      |> assign(:unknown_actor?, false)
      |> assign(:page, page)
      |> assign(:events, page.results)
    else
      :no_such_actor -> socket |> assign(:unknown_actor?, true) |> empty()
      _refused_or_failed -> socket |> assign(:unknown_actor?, false) |> empty()
    end
  end

  defp empty(socket), do: socket |> assign(:page, nil) |> assign(:events, [])

  defp filter_params(filters) do
    Map.new(~w(type actor from to), &{&1, Map.get(filters, &1, "")})
  end

  defp forbidden_message,
    do: gettext("Only platform administrators can view the instance security log.")

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  defp target_text(%{target_type: nil, target_id: nil}), do: nil

  defp target_text(%{target_type: type, target_id: id}) do
    [type, id && String.slice(id, 0, 8)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp export_path(filters), do: ~p"/editor/instance-security-log/export.csv?#{filters}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:security_log}
    >
      <.header>
        {gettext("Instance security log")}
        <:subtitle>
          {gettext(
            "Security events about this whole installation rather than one site, such as a canceled backup. Only platform administrators can see it; site administrators cannot."
          )}
        </:subtitle>
        <:actions>
          <.button
            id="instance-security-log-export"
            href={export_path(@filters)}
            variant="ghost"
            size="sm"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download CSV")}
          </.button>
        </:actions>
      </.header>

      <.form
        for={@filter_form}
        id="instance-security-log-filters"
        phx-submit="filter"
        class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-5 lg:items-end"
      >
        <.input
          field={@filter_form[:type]}
          type="select"
          label={gettext("Event")}
          prompt={gettext("All events")}
          options={SecurityLog.type_options(:instance)}
        />
        <.input
          field={@filter_form[:actor]}
          type="text"
          label={gettext("Who (email)")}
          placeholder="person@example.com"
        />
        <.input field={@filter_form[:from]} type="date" label={gettext("From (UTC)")} />
        <.input field={@filter_form[:to]} type="date" label={gettext("To (UTC)")} />
        <div class="flex items-center gap-2">
          <.button>{gettext("Apply")}</.button>
          <.button
            :if={@filters != %{}}
            id="instance-security-log-clear"
            type="button"
            variant="ghost"
            phx-click={JS.patch(~p"/editor/instance-security-log")}
          >
            {gettext("Clear")}
          </.button>
        </div>
      </.form>

      <p
        :if={@unknown_actor?}
        id="instance-security-log-unknown-actor"
        class="mt-4 text-sm text-warning-ink"
      >
        {gettext("No one with that email address is in this log.")}
      </p>

      <.empty_state
        :if={@events == []}
        id="instance-security-log-empty"
        icon="hero-shield-check"
        title={gettext("No events to show")}
        class="mt-8"
      >
        {gettext("Nothing matches these filters, or nothing has been recorded yet.")}
      </.empty_state>

      <div :if={@events != []} class="mt-6 overflow-x-auto">
        <table id="instance-security-log-events" class="w-full text-left text-sm">
          <thead>
            <tr class="border-b border-base-content/15 text-xs uppercase tracking-wide text-base-content/70">
              <th class="py-2 pr-3">{gettext("Time")}</th>
              <th class="py-2 pr-3">{gettext("Event")}</th>
              <th class="py-2 pr-3">{gettext("Who")}</th>
              <th class="py-2 pr-3">{gettext("Target")}</th>
              <th class="py-2 pr-3">{gettext("IP address")}</th>
              <th class="py-2">{gettext("Browser")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/5">
            <tr :for={event <- @events} id={"instance-security-event-#{event.id}"}>
              <td class="whitespace-nowrap py-2 pr-3 text-base-content/70">
                {format_time(event.inserted_at)}
              </td>
              <td class="py-2 pr-3">
                <.badge variant="neutral">{SecurityLog.type_label(event.type)}</.badge>
              </td>
              <td class="py-2 pr-3 break-all">{event.actor_label || "-"}</td>
              <td class="py-2 pr-3 break-all text-base-content/70">{target_text(event) || "-"}</td>
              <td class="py-2 pr-3 font-mono text-xs">{event.ip || "-"}</td>
              <td class="max-w-xs truncate py-2 text-xs text-base-content/70" title={event.user_agent}>
                {event.user_agent || "-"}
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={@page && @page.more?} class="mt-4">
          <.button
            id="instance-security-log-load-more"
            type="button"
            variant="ghost"
            phx-click="load_more"
            phx-disable-with={gettext("Loading…")}
          >
            {gettext("Load more")}
          </.button>
        </div>
      </div>

      <section id="instance-security-log-retention" class="mt-12 max-w-2xl">
        <h2 class="text-sm font-semibold">{gettext("Retention")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          <%= if @retention_days == 0 do %>
            {gettext("Events are kept forever.")}
          <% else %>
            {gettext("Events are deleted %{days} days after they happen.", days: @retention_days)}
          <% end %>
          {gettext("Set it with KILN_INSTANCE_SECURITY_LOG_RETENTION_DAYS in the environment.")}
        </p>
      </section>
    </Layouts.console>
    """
  end
end
