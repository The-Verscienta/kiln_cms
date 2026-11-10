defmodule KilnCMSWeb.SecurityLogLive do
  @moduledoc """
  The site's security audit log (#2241): who signed in, what changed on the
  access side, from where. Newest first, filterable by event type, actor
  (an email address) and a date range, with a keyset "load more", a CSV
  download of the same filters, and the retention window.

  Org-scoped and admin-only, gated the same two ways as
  `KilnCMSWeb.IpBlockLive`: the `:admin_routes` live session's
  `:live_admin_required` hook and the `KilnCMS.Security.Event` /
  `KilnCMS.CMS.SiteSecurityLog` org-admin policies. Every client-bound event
  re-checks the tier as well, because the socket outlives the mount-time check.

  Filters live in the URL (`?type=&actor=&from=&to=`) so a view can be shared
  and the download link carries exactly what is on screen; see
  `KilnCMSWeb.SecurityLog` for how they are read and why the actor field is not
  a user search.

  Everything in a row is escaped by HEEx. The actor label and the user agent
  are chosen by whoever made the request, so they are shown as text only.

  Retention `0` keeps the log forever, which keeps raw IP addresses and user
  agents forever too; the page says so whenever it is the setting.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.CMS.SiteSecurityLog
  alias KilnCMS.Security
  alias KilnCMSWeb.SecurityLog

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Security log"))
     |> assign(:filters, %{})
     |> assign(:events, [])
     |> assign(:page, nil)
     |> assign(:unknown_actor?, false)
     |> assign_retention()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = SecurityLog.parse(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filter_params(filters), as: :filters))
     |> load_first_page()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) when is_map(params) do
    if admin?(socket) do
      {:noreply, push_patch(socket, to: ~p"/editor/security-log?#{SecurityLog.parse(params)}")}
    else
      {:noreply, put_flash(socket, :error, forbidden_message())}
    end
  end

  def handle_event("load_more", _params, %{assigns: %{page: %Ash.Page.Keyset{} = page}} = socket) do
    if admin?(socket) do
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

  def handle_event("save_retention", %{"retention" => %{"days" => days}}, socket)
      when is_binary(days) do
    with true <- admin?(socket),
         {:ok, days} <- parse_days(days),
         {:ok, _row} <-
           Security.set_retention_days(days,
             actor: socket.assigns.current_user,
             tenant: socket.assigns.current_org,
             context: socket.assigns.security_context
           ) do
      {:noreply, socket |> put_flash(:info, gettext("Retention saved.")) |> assign_retention()}
    else
      false ->
        {:noreply, put_flash(socket, :error, forbidden_message())}

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Enter a whole number of days from 0 to %{max}.",
             max: SiteSecurityLog.max_days()
           )
         )}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, forbidden_message())}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("The retention window could not be saved."))}
    end
  end

  def handle_event("save_retention", _params, socket), do: {:noreply, socket}

  defp admin?(socket), do: KilnCMSWeb.LiveUserAuth.effective_tier(socket) == :admin

  defp parse_days(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} when days >= 0 -> {:ok, days}
      _other -> :error
    end
  end

  defp load_first_page(socket) do
    %{current_user: user, current_org: org, filters: filters} = socket.assigns

    with true <- admin?(socket),
         {:ok, args} <- SecurityLog.arguments(filters, user, org),
         {:ok, %Ash.Page.Keyset{} = page} <-
           Security.list_events(args,
             actor: user,
             tenant: org,
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

  defp assign_retention(socket) do
    days = Security.retention_days(socket.assigns.current_org)

    socket
    |> assign(:retention_days, days)
    |> assign(:retention_form, to_form(%{"days" => to_string(days)}, as: :retention))
  end

  defp filter_params(filters) do
    Map.new(~w(type actor from to), &{&1, Map.get(filters, &1, "")})
  end

  defp forbidden_message,
    do: gettext("You don't have permission to view or change this site's security log.")

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  defp target_text(%{target_type: nil, target_id: nil}), do: nil

  defp target_text(%{target_type: type, target_id: id}) do
    [type, id && String.slice(id, 0, 8)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp export_path(filters), do: ~p"/editor/security-log/export.csv?#{filters}"

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
        {gettext("Security log")}
        <:subtitle>
          {gettext(
            "Sign-ins, lockouts, second factors, passkeys, roles, API keys and sign-in settings on this site. Only administrators can see it."
          )}
        </:subtitle>
        <:actions>
          <.button
            id="security-log-export"
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
        id="security-log-filters"
        phx-submit="filter"
        class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-5 lg:items-end"
      >
        <.input
          field={@filter_form[:type]}
          type="select"
          label={gettext("Event")}
          prompt={gettext("All events")}
          options={SecurityLog.type_options()}
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
            id="security-log-clear"
            type="button"
            variant="ghost"
            phx-click={JS.patch(~p"/editor/security-log")}
          >
            {gettext("Clear")}
          </.button>
        </div>
      </.form>

      <p :if={@unknown_actor?} id="security-log-unknown-actor" class="mt-4 text-sm text-warning-ink">
        {gettext("No member of this site has that email address.")}
      </p>

      <.empty_state
        :if={@events == []}
        id="security-log-empty"
        icon="hero-shield-check"
        title={gettext("No events to show")}
        class="mt-8"
      >
        {gettext("Nothing matches these filters, or nothing has been recorded yet.")}
      </.empty_state>

      <div :if={@events != []} class="mt-6 overflow-x-auto">
        <table id="security-log-events" class="w-full text-left text-sm">
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
            <tr :for={event <- @events} id={"security-event-#{event.id}"}>
              <td class="whitespace-nowrap py-2 pr-3 text-base-content/70">
                {format_time(event.inserted_at)}
              </td>
              <td class="py-2 pr-3">
                <.badge variant={
                  if event.type in [
                       :sign_in_failed,
                       :sign_in_locked,
                       :sign_in_unlock_refused,
                       :api_key_reuse_detected
                     ],
                     do: "warning",
                     else: "neutral"
                }>
                  {SecurityLog.type_label(event.type)}
                </.badge>
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
            id="security-log-load-more"
            type="button"
            variant="ghost"
            phx-click="load_more"
            phx-disable-with={gettext("Loading…")}
          >
            {gettext("Load more")}
          </.button>
        </div>
      </div>

      <section id="security-log-retention" class="mt-12 max-w-2xl">
        <h2 class="text-sm font-semibold">{gettext("Retention")}</h2>
        <p class="mt-1 text-sm text-base-content/70">
          <%= if @retention_days == 0 do %>
            {gettext("Events are kept forever.")}
          <% else %>
            {gettext("Events are deleted %{days} days after they happen.", days: @retention_days)}
          <% end %>
        </p>

        <div
          :if={@retention_days == 0}
          id="security-log-retention-warning"
          role="status"
          class="mt-3 flex gap-3 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <p>
            {gettext(
              "While retention is 0, raw IP addresses and browser details of everyone who signs in are kept indefinitely. Set a number of days unless you have a reason to keep them."
            )}
          </p>
        </div>

        <.form
          for={@retention_form}
          id="security-log-retention-form"
          phx-submit="save_retention"
          class="mt-4 flex items-end gap-3"
        >
          <.input
            field={@retention_form[:days]}
            type="number"
            min="0"
            max={SiteSecurityLog.max_days()}
            label={gettext("Keep events for (days)")}
            hint={gettext("0 keeps them forever.")}
            required
          />
          <.button phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
        </.form>
      </section>
    </Layouts.console>
    """
  end
end
