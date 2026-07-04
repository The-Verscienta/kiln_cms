defmodule ShowcaseWeb.PostLive do
  @moduledoc """
  A single document, fetched as typed blocks via the fired-artifact API
  (`GET /api/content/:type/:slug?surface=json`) and rendered on the BEAM by
  `ShowcaseWeb.Blocks`. Serves `/blog/:slug` (posts) and `/doc/:type/:slug`
  (any content type, incl. pages).
  """
  use ShowcaseWeb, :live_view

  alias ShowcaseWeb.Blocks

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    type = params["type"] || "post"
    slug = params["slug"]

    socket =
      case Showcase.Kiln.fetch_document(type, slug, locale: socket.assigns.locale) do
        {:ok, doc} -> assign(socket, doc: doc, state: :ok, page_title: doc["title"])
        :not_found -> assign(socket, doc: nil, state: :not_found, page_title: "Not found")
        :compiling -> assign(socket, doc: nil, state: :compiling, page_title: "One moment…")
        {:error, _} -> assign(socket, doc: nil, state: :error, page_title: "Error")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="back">← All posts</.link>

    <%= case @state do %>
      <% :ok -> %>
        <article>
          <h1>{@doc["title"]}</h1>
          <Blocks.content blocks={@doc["blocks"] || []} />
        </article>
      <% :not_found -> %>
        <h1>Not found</h1>
        <p class="empty">No published document matched that address in this locale.</p>
      <% :compiling -> %>
        <h1>One moment…</h1>
        <p class="empty">
          KilnCMS is still compiling this document's artifact. Refresh in a couple of seconds.
        </p>
      <% :error -> %>
        <h1>Something went wrong</h1>
        <p class="flash flash-error">
          Couldn't reach KilnCMS at <code>{Showcase.Kiln.base_url()}</code>.
        </p>
    <% end %>
    """
  end
end
