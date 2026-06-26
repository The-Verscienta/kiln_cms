defmodule KilnCMSWeb.SearchPaletteLive do
  @moduledoc """
  Editor command palette (`/editor/search`, reachable via ⌘/Ctrl-K): a single
  search box that runs `KilnCMS.Search.global/2` across pages, posts, and media
  and links straight to where each result is edited. Each search is recorded for
  analytics. Editor-gated by the `:editor_routes` live session.
  """
  use KilnCMSWeb, :live_view

  alias KilnCMS.Search
  alias KilnCMS.Search.Highlight

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:searched, false)
     |> assign(:retention_days, KilnCMS.Analytics.SearchQuery.retention_days())
     |> assign(:results, empty())}
  end

  defp empty, do: %{pages: [], posts: [], media: []}

  @impl true
  def handle_event("search", %{"q" => raw}, socket) do
    query = String.trim(raw)

    socket =
      if query == "" do
        socket |> assign(:query, "") |> assign(:searched, false) |> assign(:results, empty())
      else
        results =
          Search.global(query, actor: socket.assigns.current_user, limit: 8, highlight: true)

        total = length(results.pages) + length(results.posts) + length(results.media)
        record_query_async(query, total)

        socket |> assign(:query, query) |> assign(:searched, true) |> assign(:results, results)
      end

    {:noreply, socket}
  end

  # Record the search for analytics off the LiveView's process so a debounced
  # keystroke doesn't block on the DB write. Best-effort and bounded by the
  # shared Task.Supervisor's max_children (drops under load); failures swallowed.
  defp record_query_async(query, total) do
    Task.Supervisor.start_child(KilnCMS.TaskSupervisor, fn ->
      try do
        Search.record_query(query, total)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp result_count(%{pages: p, posts: o, media: m}), do: length(p) + length(o) + length(m)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :count, result_count(assigns.results))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto max-w-2xl space-y-6">
        <div>
          <h1 class="text-2xl font-semibold">Search</h1>
          <p class="text-sm text-base-content/60">
            Find pages, posts, and media — press ⌘K / Ctrl-K from anywhere to jump here.
          </p>
          <p class="mt-1 text-xs text-base-content/40">
            Searches are logged anonymously — no user ID or IP — to improve content discovery,
            and purged after {@retention_days} days.
          </p>
        </div>

        <form phx-change="search" id="palette-search">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="Search content…"
            autocomplete="off"
            autofocus
            phx-debounce="150"
            class="w-full rounded-lg border border-base-content/20 bg-transparent px-4 py-2.5 text-base"
          />
        </form>

        <p :if={@searched and @count == 0} class="text-sm text-base-content/60">
          No results for “{@query}”.
        </p>

        <div :if={@count > 0} class="space-y-6">
          <.section :if={@results.pages != []} title="Pages">
            <.content_row :for={p <- @results.pages} type="page" record={p} />
          </.section>
          <.section :if={@results.posts != []} title="Posts">
            <.content_row :for={p <- @results.posts} type="post" record={p} />
          </.section>
          <.section :if={@results.media != []} title="Media">
            <.link
              :for={m <- @results.media}
              navigate={~p"/media"}
              class="block rounded px-3 py-2 hover:bg-base-200"
            >
              <span class="font-medium">{m.filename}</span>
              <span :if={m.alt} class="ml-2 text-xs text-base-content/50">{m.alt}</span>
            </.link>
          </.section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div>
      <h2 class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/40">
        {@title}
      </h2>
      <div class="divide-y divide-base-content/5 rounded border border-base-content/10">
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
      <span class="ml-2 text-xs text-base-content/50">/{@record.slug}</span>
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
