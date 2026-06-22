defmodule KilnCMSWeb.SitemapControllerTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS.{Page, Post}

  defp published_page(slug),
    do: Ash.Seed.seed!(Page, %{title: "P", slug: slug, state: :published})

  defp published_post(slug),
    do: Ash.Seed.seed!(Post, %{title: "Q", slug: slug, state: :published})

  defp draft_page(slug), do: Ash.Seed.seed!(Page, %{title: "D", slug: slug, state: :draft})

  test "GET /sitemap.xml lists published pages and posts, excludes drafts", %{conn: conn} do
    n = System.unique_integer([:positive])
    published_page("about-#{n}")
    published_post("hello-#{n}")
    draft_page("secret-#{n}")

    conn = get(conn, ~p"/sitemap.xml")

    assert response_content_type(conn, :xml)
    body = response(conn, 200)
    assert body =~ "<loc>http://localhost:4000/about-#{n}</loc>"
    assert body =~ "<loc>http://localhost:4000/blog/hello-#{n}</loc>"
    refute body =~ "secret-#{n}"
  end

  test "GET /robots.txt points at the sitemap", %{conn: conn} do
    conn = get(conn, ~p"/robots.txt")

    body = response(conn, 200)
    assert response_content_type(conn, :txt)
    assert body =~ "User-agent: *"
    assert body =~ "Sitemap: http://localhost:4000/sitemap.xml"
  end
end
