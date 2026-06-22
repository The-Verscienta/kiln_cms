defmodule KilnCMSWeb.ContentController do
  @moduledoc """
  Public content delivery — renders **published** Pages and Posts as HTML for
  anonymous site visitors (the human-facing counterpart to the headless
  GraphQL/JSON:API endpoints).

  URL structure matches the sitemap: pages at `/<slug>`, posts at
  `/blog/<slug>`, and a `/blog` index. Only published content is reachable; the
  read actions filter on `state == :published`, so an unpublished slug 404s
  rather than leaking a draft.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS

  def show_page(conn, %{"slug" => slug}) do
    case CMS.get_published_page_by_slug!(slug, not_found_error?: false, authorize?: false) do
      nil -> not_found(conn)
      page -> render_content(conn, :show_page, page)
    end
  end

  def show_post(conn, %{"slug" => slug}) do
    case CMS.get_published_post_by_slug!(slug, not_found_error?: false, authorize?: false) do
      nil -> not_found(conn)
      post -> render_content(conn, :show_post, post)
    end
  end

  def blog_index(conn, _params) do
    posts = CMS.list_published_posts!(authorize?: false)

    conn
    |> assign(:page_title, "Blog")
    |> assign(:meta_description, "Latest posts.")
    |> render(:blog_index, posts: posts)
  end

  # Assign SEO metadata (read by the root layout) and the normalized blocks,
  # then render. `record` is a published Page or Post.
  defp render_content(conn, template, record) do
    conn
    |> assign(:page_title, record.seo_title || record.title)
    |> assign(:meta_description, record.seo_description)
    |> assign(:canonical_url, record.canonical_url)
    |> assign(:og_image, record.seo_image)
    |> assign(:og_type, "article")
    |> render(template, record: record, blocks: blocks(record))
  end

  defp blocks(record) do
    record.blocks
    |> List.wrap()
    |> Enum.map(&%{type: to_string(&1.type), content: &1.content})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(KilnCMSWeb.ErrorHTML)
    |> render(:"404")
  end
end
