defmodule KilnCMSWeb.SearchPaletteLive do
  @moduledoc """
  Editor command palette (`/editor/search`, reachable via ⌘/Ctrl-K): a single
  search box that runs `KilnCMS.Search.global/2` across pages, posts, and media
  and links straight to where each result is edited. Each search is recorded for
  analytics. Editor-gated by the `:editor_routes` live session.

  It also searches the console's own screens (#1319), listed first. An admin
  who types "backups" almost always wants the Backups screen, not a post that
  mentions backups, and settings are spread across ~25 screens that no sidebar
  scan finds quickly. The screen list is `KilnCMSWeb.ConsoleNav` — the same one
  the sidebar draws, already filtered to what this actor may open, so the
  palette can never offer a door that only bounces them.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Search
  alias KilnCMS.Search.Highlight
  alias KilnCMSWeb.ConsoleNav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Search"))
     |> assign(:query, "")
     |> assign(:searched, false)
     |> assign(:retention_days, KilnCMS.Analytics.SearchQuery.retention_days())
     |> assign(:screens, [])
     |> assign(:results, empty())}
  end

  defp empty,
    do: %{
      pages: [],
      posts: [],
      entries: [],
      media: [],
      categories: [],
      tags: [],
      tag_groups: []
    }

  @impl true
  # `String.trim/1` raises on a list or a map (#764).
  def handle_event("search", %{"q" => raw}, socket) when is_binary(raw) do
    query = String.trim(raw)

    socket =
      if query == "" do
        socket
        |> assign(:query, "")
        |> assign(:searched, false)
        |> assign(:screens, [])
        |> assign(:results, empty())
      else
        results =
          Search.global(query,
            actor: socket.assigns.current_user,
            # Scope the palette to the editor's current site (#336).
            tenant: socket.assigns.current_org,
            limit: 8,
            highlight: true
          )

        # Content + media hits; taxonomy name matches and console screens don't
        # count as found documents for analytics — "did the search find a
        # document?" is the question that metric answers, and a nav destination
        # that matches by name is not evidence either way.
        total =
          length(results.pages) + length(results.posts) + length(results.entries) +
            length(results.media)

        record_query_async(query, total, socket.assigns.current_org)

        socket
        |> assign(:query, query)
        |> assign(:searched, true)
        |> assign(
          :screens,
          ConsoleNav.search(query, socket.assigns.current_user, socket.assigns.current_org)
        )
        |> assign(:results, results)
      end

    {:noreply, socket}
  end

  # Record the search for analytics off the LiveView's process so a debounced
  # keystroke doesn't block on the DB write. Best-effort and bounded by the
  # shared Task.Supervisor's max_children (drops under load); failures swallowed.
  # `:async_analytics` is off under test so the write stays on the test's SQL
  # sandbox connection rather than leaking from a detached task.
  defp record_query_async(query, total, org) do
    if Application.get_env(:kiln_cms, :async_analytics, true) do
      Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
        record_query(query, total, org)
      end)
    else
      record_query(query, total, org)
    end

    :ok
  end

  # The recorded query lands in the current site (epic #336).
  defp record_query(query, total, org) do
    Search.record_query(query, total, tenant: org)
  rescue
    _ -> :ok
  end

  defp result_count(%{
         pages: p,
         posts: o,
         entries: e,
         media: m,
         categories: c,
         tags: t,
         tag_groups: g
       }),
       do: length(p) + length(o) + length(e) + length(m) + length(c) + length(t) + length(g)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :count, result_count(assigns.results) + length(assigns.screens))

    ~H"""
    <Layouts.console
      flash={@flash}
      current_user={@current_user}
      current_org={@current_org}
      page_title={@page_title}
    >
      <div class="mx-auto max-w-2xl space-y-6">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Search")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Find pages, posts, media and settings screens — press ⌘K / Ctrl-K from anywhere to jump here."
            )}
          </p>
          <p class="mt-1 text-xs text-base-content/70">
            {gettext(
              "Searches are logged anonymously — no user ID or IP — to improve content discovery, and purged after %{days} days.",
              days: @retention_days
            )}
          </p>
        </div>

        <form phx-change="search" id="palette-search" role="search">
          <label for="palette-q" class="sr-only">{gettext("Search content and settings")}</label>
          <input
            id="palette-q"
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search content and settings…")}
            aria-label={gettext("Search content and settings")}
            aria-describedby="search-status"
            autocomplete="off"
            autofocus
            phx-debounce="150"
            class="field-input text-base"
          />
        </form>

        <%!-- Announce result changes to screen readers (#176). --%>
        <p id="search-status" role="status" aria-live="polite" class="sr-only">
          <%= cond do %>
            <% @searched and @count == 0 -> %>
              {gettext("No results for “%{query}”.", query: @query)}
            <% @searched -> %>
              {gettext("%{count} results for “%{query}”.", count: @count, query: @query)}
            <% true -> %>
          <% end %>
        </p>

        <p :if={@searched and @count == 0} class="text-sm text-base-content/70">
          {gettext("No results for “%{query}”.", query: @query)}
        </p>

        <div :if={@count > 0} class="space-y-6">
          <%!-- Screens lead (#1319): a match on a destination is an unambiguous
                answer, and the content hits below it are not. The description
                is shown because a keyword match ("rss" → Feeds) otherwise
                leaves the reader to guess why this screen came up. --%>
          <.section :if={@screens != []} title={gettext("Go to")}>
            <.link
              :for={screen <- @screens}
              navigate={screen.path}
              class="flex items-start gap-3 rounded px-3 py-2 hover:bg-base-200"
            >
              <.icon name={screen.icon} class="mt-0.5 size-4 shrink-0 text-base-content/50" />
              <span class="min-w-0">
                <span class="font-medium">{screen.label}</span>
                <span :if={screen[:section]} class="ml-2 text-xs text-base-content/60">
                  {screen.section}
                </span>
                <span :if={screen[:description]} class="block text-xs text-base-content/70">
                  {screen.description}
                </span>
              </span>
            </.link>
          </.section>
          <.section :if={@results.pages != []} title={gettext("Pages")}>
            <.content_row :for={p <- @results.pages} type="page" record={p} />
          </.section>
          <.section :if={@results.posts != []} title={gettext("Posts")}>
            <.content_row :for={p <- @results.posts} type="post" record={p} />
          </.section>
          <.section :if={@results.entries != []} title={gettext("Custom content")}>
            <.content_row :for={e <- @results.entries} type={e.type_name} record={e} />
          </.section>
          <.section :if={@results.media != []} title={gettext("Media")}>
            <.link
              :for={m <- @results.media}
              navigate={~p"/media?#{%{id: m.id}}"}
              class="block rounded px-3 py-2 hover:bg-base-200"
            >
              <span class="font-medium">{m.filename}</span>
              <span :if={m.alt} class="ml-2 text-xs text-base-content/70">{m.alt}</span>
            </.link>
          </.section>
          <.section
            :if={@results.categories != [] or @results.tags != [] or @results.tag_groups != []}
            title={gettext("Taxonomy")}
          >
            <.link
              :for={c <- @results.categories}
              navigate={~p"/editor/taxonomy"}
              class="block rounded px-3 py-2 hover:bg-base-200"
            >
              <span class="font-medium">{c.name}</span>
              <span class="ml-2 text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Category")}
              </span>
            </.link>
            <.link
              :for={t <- @results.tags}
              navigate={~p"/editor/taxonomy"}
              class="block rounded px-3 py-2 hover:bg-base-200"
            >
              <span class="font-medium">{t.name}</span>
              <span class="ml-2 text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Tag")}
              </span>
            </.link>
            <.link
              :for={g <- @results.tag_groups}
              navigate={~p"/editor/taxonomy"}
              class="block rounded px-3 py-2 hover:bg-base-200"
            >
              <span class="font-medium">{g.name}</span>
              <span class="ml-2 text-xs uppercase tracking-wide text-base-content/50">
                {gettext("Tag group")}
              </span>
            </.link>
          </.section>
        </div>
      </div>
    </Layouts.console>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div>
      <h2 class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/70">
        {@title}
      </h2>
      <div class="card divide-y divide-base-content/5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :record, :map, required: true

  defp content_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/editor/content/#{@type}/#{@record.id}"}
      class="block rounded px-3 py-2 hover:bg-base-200"
    >
      <span class="font-medium">{@record.title}</span>
      <span class="ml-2 text-xs text-base-content/70">/{@record.slug}</span>
      <p
        :if={snippet(@record)}
        class="mt-0.5 line-clamp-2 text-xs text-base-content/60 [&_mark]:rounded-sm [&_mark]:bg-warning/30 [&_mark]:px-0.5 [&_mark]:text-base-content"
      >
        {Highlight.to_safe_html(snippet(@record))}
      </p>
    </.link>
    """
  end

  # The loaded `highlight` snippet for a result, or nil when absent/blank.
  defp snippet(%{highlight: h}) when is_binary(h) and h != "", do: h
  defp snippet(_), do: nil
end
