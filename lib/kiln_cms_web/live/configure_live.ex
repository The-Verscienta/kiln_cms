defmodule KilnCMSWeb.ConfigureLive do
  @moduledoc """
  The configuration hub (`/editor/configure`, #1319): every settings screen the
  viewer may open on one page, grouped as the sidebar groups them, each with a
  line saying what it is for, and a filter box over the lot.

  ## Why a hub at all

  The console had no screen that *was* configuration. `/editor/settings` — the
  one screen named Settings, now labelled "Your settings" — is a person's own
  profile, password and 2FA; everything about the site lived behind two dozen
  sidebar links whose names you had to already know. An admin looking for
  "where do I turn off full-text RSS" had to guess between Feeds, Delivery and
  Code injection, and the sidebar offers no way to guess: a link is a name with
  no explanation attached.

  So this page is descriptions first. Every card carries the one line the
  sidebar cannot, and the filter matches those descriptions and a keyword list
  as well as the names — "rss" finds Feeds, "stripe" finds Billing, "2fa" finds
  your own settings — through `KilnCMSWeb.ConsoleNav.rank/2`, the same match
  the ⌘K palette runs over the same list.

  ## What it does not do

  It holds no settings of its own and writes nothing. It is a map, and every
  screen it points at keeps its own authorization — `ConsoleNav.nav/2` drops
  what this viewer could not open anyway, but that is so the map is honest, not
  so it is safe.

  Admin-only, by the `:admin_routes` live_session.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMSWeb.ConsoleNav

  @impl true
  def mount(_params, _session, socket) do
    nav = ConsoleNav.nav(socket.assigns.current_user, socket.assigns.current_org)

    {:ok,
     socket
     |> assign(:page_title, gettext("Configure"))
     |> assign(:query, "")
     |> assign(:groups, nav.configure_groups)
     |> assign(:matches, nil)}
  end

  @impl true
  # `String.trim/1` raises on a list or a map (#764).
  def handle_event("filter", %{"q" => raw}, socket) when is_binary(raw) do
    query = String.trim(raw)
    matches = if query != "", do: filter_groups(socket.assigns.groups, query)

    {:noreply, socket |> assign(:query, query) |> assign(:matches, matches)}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  # Keep the grouping while filtering rather than collapsing to a flat list: a
  # match is easier to place when you can see it is a Content model thing.
  defp filter_groups(groups, query) do
    groups
    |> Enum.map(fn group ->
      matching =
        Enum.filter(group.items, &ConsoleNav.rank(Map.put(&1, :section, group.label), query))

      %{group | items: matching}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  defp match_count(groups), do: Enum.sum(Enum.map(groups, &length(&1.items)))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shown, assigns.matches || assigns.groups)

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
      active={:configure}
    >
      <.header>
        {gettext("Configure")}
        <:subtitle>
          {gettext(
            "Everything you can change about this site, and about this deployment. Your own profile, password and sign-in live under Your settings instead."
          )}
        </:subtitle>
      </.header>

      <form phx-change="filter" id="configure-filter" role="search" class="mt-6">
        <label for="configure-q" class="sr-only">{gettext("Filter settings")}</label>
        <input
          id="configure-q"
          type="text"
          name="q"
          value={@query}
          placeholder={gettext("Filter settings — try “rss”, “passkey”, “redirect”…")}
          aria-describedby="configure-status"
          autocomplete="off"
          phx-debounce="150"
          class="field-input"
        />
      </form>

      <%!-- Announce filter results to screen readers (#176). --%>
      <p id="configure-status" role="status" aria-live="polite" class="sr-only">
        <%= if @matches do %>
          {ngettext(
            "%{count} setting matches “%{query}”.",
            "%{count} settings match “%{query}”.",
            match_count(@matches),
            query: @query
          )}
        <% end %>
      </p>

      <p :if={@matches == []} class="mt-6 text-sm text-base-content/70">
        {gettext("Nothing here matches “%{query}”.", query: @query)}
      </p>

      <div class="mt-8 space-y-10">
        <section :for={group <- @shown} id={"configure-group-#{group.key}"}>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            {group.label}
          </h2>
          <%!-- A note on the section, not a badge per card: every screen in the
                operator band is platform-gated (see `ConsoleNav`), so what is
                true of one is true of all of them. --%>
          <p :if={group[:operator?]} class="mt-1 text-sm text-base-content/70">
            {gettext("Running the deployment, not just this site.")}
          </p>
          <p :if={group.key == :account} class="mt-1 text-sm text-base-content/70">
            {gettext("Yours alone — nobody else on the team sees or inherits these.")}
          </p>

          <ul class="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <li :for={item <- group.items} id={"configure-card-#{item.key}"}>
              <.link
                navigate={item.path}
                class="card card-pad flex h-full gap-3 transition hover:border-primary/40 hover:bg-base-200/40"
              >
                <span class="grid size-9 shrink-0 place-items-center rounded-md bg-base-200 text-base-content/70">
                  <.icon name={item.icon} class="size-5" />
                </span>
                <span class="min-w-0">
                  <span class="block font-medium">{item.label}</span>
                  <span :if={item[:description]} class="mt-0.5 block text-sm text-base-content/70">
                    {item.description}
                  </span>
                </span>
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.console>
    """
  end
end
