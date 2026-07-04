defmodule ShowcaseWeb.BlogLive do
  @moduledoc """
  The blog index — published posts, fetched from KilnCMS over JSON:API
  (`GET /api/json/posts/published`) in the active locale.
  """
  use ShowcaseWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_posts(socket)}
  end

  defp load_posts(socket) do
    case Showcase.Kiln.list_posts(locale: socket.assigns.locale) do
      {:ok, posts} -> assign(socket, posts: posts, error: nil)
      {:error, _} -> assign(socket, posts: [], error: true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>From the blog</h1>
    <p class="page-intro">
      Rendered by a database-free Phoenix/LiveView app that reads KilnCMS purely over HTTP.
    </p>

    <p :if={@error} class="flash flash-error">
      Couldn't reach KilnCMS at <code>{Showcase.Kiln.base_url()}</code>. Is it running and seeded?
    </p>

    <p :if={!@error and @posts == []} class="empty">
      No published posts in this locale yet.
    </p>

    <ul :if={@posts != []} class="post-list">
      <li :for={post <- @posts} class="post-card">
        <h2><.link navigate={~p"/blog/#{post.slug}"}>{post.title}</.link></h2>
        <p :if={post.excerpt} class="excerpt">{post.excerpt}</p>
        <p :if={post.published_at} class="meta">{format_date(post.published_at)}</p>
      </li>
    </ul>
    """
  end

  defp format_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%B %-d, %Y")
      _ -> iso
    end
  end

  defp format_date(_), do: nil
end
