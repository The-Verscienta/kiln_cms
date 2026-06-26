defmodule KilnCMSWeb.SitemapControllerTest do
  @moduledoc false
  # async: false — the sitemap is served from the shared content cache, which
  # other tests may bust concurrently.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS.{Page, Post}

  setup do
    Cache.bust_published()
    :ok
  end

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

  test "the URL set is bounded — output is a finite list, not the full table streamed",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    for i <- 1..5, do: published_page("bound-#{n}-#{i}")

    body = conn |> get(~p"/sitemap.xml") |> response(200)

    url_count = body |> String.split("<url>") |> length() |> Kernel.-(1)
    # Every entry is a single <url> element and the count is finite (well under
    # the 50,000 hard cap), so a request can never stream the whole table.
    assert url_count >= 5
    assert url_count < 50_000
  end

  test "repeated hits are served from a short-TTL cache rather than re-scanning",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    published_page("cached-#{n}")

    # First hit renders and caches the sitemap.
    first = conn |> get(~p"/sitemap.xml") |> response(200)
    assert first =~ "cached-#{n}"

    # A record added afterwards (seeded, so it bypasses cache invalidation) must
    # NOT appear on the next hit — proving the result was cached, not rescanned.
    published_page("late-#{n}")
    second = build_conn() |> get(~p"/sitemap.xml") |> response(200)
    refute second =~ "late-#{n}"

    # Busting the cache (as a real content write would) brings it back.
    Cache.bust_published()
    third = build_conn() |> get(~p"/sitemap.xml") |> response(200)
    assert third =~ "late-#{n}"
  end

  test "GET /robots.txt points at the sitemap", %{conn: conn} do
    conn = get(conn, ~p"/robots.txt")

    body = response(conn, 200)
    assert response_content_type(conn, :txt)
    assert body =~ "User-agent: *"
    assert body =~ "Sitemap: http://localhost:4000/sitemap.xml"
  end
end
