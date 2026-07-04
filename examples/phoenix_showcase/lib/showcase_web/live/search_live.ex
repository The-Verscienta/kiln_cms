defmodule ShowcaseWeb.SearchLive do
  @moduledoc """
  Search-as-you-type. Each keystroke (debounced) runs the KilnCMS GraphQL
  `searchPosts` query server-side and re-renders the results over the LiveView
  socket — no client-side API calls, so no CORS needed for this path.
  """
  use ShowcaseWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, query: "", results: [], searched?: false)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    results =
      case Showcase.Kiln.search_posts(query, locale: socket.assigns.locale) do
        {:ok, hits} -> hits
        {:error, _} -> []
      end

    {:noreply, assign(socket, query: query, results: results, searched?: query != "")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Search</h1>
    <p class="page-intro">
      Hybrid keyword + semantic search, served by KilnCMS GraphQL and run on each keystroke.
    </p>

    <form phx-change="search" phx-submit="search">
      <label class="field">
        <span>Search published posts</span>
        <input
          type="search"
          name="q"
          value={@query}
          placeholder="Try a topic…"
          phx-debounce="250"
          autocomplete="off"
          autofocus
        />
      </label>
    </form>

    <div class="results">
      <p :if={@searched? and @results == []} class="empty">
        No matches for “{@query}”.
      </p>

      <ul :if={@results != []} class="post-list">
        <li :for={hit <- @results} class="post-card">
          <h2><.link navigate={~p"/blog/#{hit.slug}"}>{hit.title}</.link></h2>
          <p :if={hit.excerpt} class="excerpt">{hit.excerpt}</p>
        </li>
      </ul>
    </div>
    """
  end
end
