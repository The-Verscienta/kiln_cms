defmodule KilnCMSWeb.FeedControllerTest do
  @moduledoc """
  Atom and JSON Feed syndication (#486). The feed is a *public* document fetched
  by anonymous readers, aggregators and mail tools, so most of what matters here
  is what must not appear in it.
  """
  # async: false — feeds are served from the shared content cache, which other
  # tests bust concurrently.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.{Page, Post}
  alias KilnCMS.Feeds

  setup do
    Cache.bust_published()
    previous = Application.get_env(:kiln_cms, :feeds, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :feeds, previous) end)
    :ok
  end

  defp put_config(opts), do: Application.put_env(:kiln_cms, :feeds, opts)

  # Through the real actions, so publish hooks (firing, cache busting) run.
  # `Ash.Seed.seed!` writes the row directly and skips all of them.
  defp real_published_post(body_text \\ "Some prose") do
    n = System.unique_integer([:positive])

    post =
      CMS.create_post!(
        %{
          title: "Real post #{n}",
          slug: "feed-real-#{n}",
          excerpt: "Real summary #{n}",
          blocks: [%{type: :heading, content: body_text, order: 0}]
        },
        actor: admin()
      )

    published = CMS.publish_post!(post, actor: admin())
    KilnCMS.DataCase.drain_oban()
    published
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "feed-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_post(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{
          title: "Post #{n}",
          slug: "feed-post-#{n}",
          excerpt: "Summary #{n}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  describe "GET /feed.xml" do
    test "serves Atom listing published records", %{conn: conn} do
      post = published_post()

      conn = get(conn, ~p"/feed.xml")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      body = response(conn, 200)

      assert body =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
      assert body =~ "<title>#{post.title}</title>"
      assert body =~ ~s(href="http://localhost:4000/blog/#{post.slug}")
      assert body =~ post.excerpt
    end

    test "omits drafts", %{conn: conn} do
      n = System.unique_integer([:positive])
      Ash.Seed.seed!(Post, %{title: "Draft", slug: "feed-draft-#{n}", state: :draft})

      refute response(get(conn, ~p"/feed.xml"), 200) =~ "feed-draft-#{n}"
    end

    test "omits published-but-audience-gated records", %{conn: conn} do
      # Published is not public. A member-only post is published and paywalled,
      # and a feed is fetched by anonymous readers — this is the difference
      # between a feed and a leak.
      gated = published_post(%{audience: :member, title: "Members only"})

      body = response(get(conn, ~p"/feed.xml"), 200)

      refute body =~ gated.slug
      refute body =~ "Members only"
    end

    test "entry ids survive a slug rename", %{conn: conn} do
      post = published_post()

      body = response(get(conn, ~p"/feed.xml"), 200)
      assert body =~ "<id>tag:localhost,"
      # The id addresses the record, not the page — a rename must not re-notify
      # every subscriber.
      assert body =~ "post/#{post.id}</id>"
      refute body =~ "<id>http://localhost:4000/blog/#{post.slug}</id>"
    end

    test "an empty feed is still a valid document", %{conn: conn} do
      # Atom requires `<updated>`; a reader rejects the document without one.
      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "<updated>"
      assert body =~ "</feed>"
    end
  end

  describe "GET /feed.json" do
    test "serves JSON Feed 1.1", %{conn: conn} do
      post = published_post()

      conn = get(conn, ~p"/feed.json")
      assert response_content_type(conn, :json) =~ "application/feed+json"

      feed = Jason.decode!(response(conn, 200))

      assert feed["version"] == "https://jsonfeed.org/version/1.1"
      assert feed["feed_url"] == "http://localhost:4000/feed.json"
      assert Enum.any?(feed["items"], &(&1["title"] == post.title))
    end
  end

  describe "per-type feeds" do
    test "a type's own feed carries only that type", %{conn: conn} do
      post = published_post()
      n = System.unique_integer([:positive])
      Ash.Seed.seed!(Page, %{title: "A page", slug: "feed-page-#{n}", state: :published})

      body = response(get(conn, ~p"/blog/feed.xml"), 200)

      assert body =~ post.slug
      refute body =~ "feed-page-#{n}"
    end

    test "an unknown segment is a 404, not an empty feed", %{conn: conn} do
      # An empty feed for `/nonsense/feed.xml` would tell a reader the type
      # exists and has no content, which is a different (and wrong) claim.
      assert response(get(conn, "/nonsense/feed.xml"), 404)
    end

    test "an excluded type serves no feed of its own", %{conn: conn} do
      put_config(exclude: ["post"])
      post = published_post()

      assert response(get(conn, ~p"/blog/feed.xml"), 404)
      refute response(get(conn, ~p"/feed.xml"), 200) =~ post.slug
    end
  end

  describe "entry bodies" do
    test "carry the summary by default, not the body", %{conn: conn} do
      post = published_post()

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "<summary type=\"html\">#{post.excerpt}</summary>"
      refute body =~ "<content type=\"html\">"
    end

    test "carry the rendered body when the type opts in", %{conn: conn} do
      put_config(full_content: ["post"])
      post = real_published_post("Body text here")

      body = response(get(conn, ~p"/feed.xml"), 200)

      # The fired `:web` artifact, escaped into `<content>`. Asserting the
      # actual prose, not just that one of the two elements is present — the
      # earlier version of this test held for every possible implementation.
      assert body =~ "<content type=\"html\">"
      assert body =~ "Body text here"
      refute body =~ "<summary type=\"html\">#{post.excerpt}</summary>"
    end

    test "an unfired record degrades to its summary instead of failing", %{conn: conn} do
      put_config(full_content: ["post"])
      post = published_post()

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "<summary type=\"html\">#{post.excerpt}</summary>"
      assert body =~ "</feed>"
    end
  end

  describe "cache invalidation" do
    test "an actual publish drops the cached feed", %{conn: conn} do
      first = real_published_post()
      assert response(get(conn, ~p"/feed.xml"), 200) =~ first.slug

      # Through the real action, so this exercises the `BustContentCache` hook
      # rather than a hand-rolled `Cache.bust_feeds/2` — without that wiring the
      # 5-minute TTL hides the new post from every subscriber, and a feed's
      # whole job is to be the thing that notices.
      second = real_published_post()

      assert response(get(conn, ~p"/feed.xml"), 200) =~ second.slug
    end
  end

  describe "autodiscovery" do
    test "a delivery page advertises the site and type feeds", %{conn: conn} do
      post = published_post()

      html = response(get(conn, ~p"/blog/#{post.slug}"), 200)

      assert html =~ ~s(rel="alternate" type="application/atom+xml")
      assert html =~ ~s(href="http://localhost:4000/feed.xml")
      assert html =~ ~s(href="http://localhost:4000/blog/feed.xml")
      assert html =~ ~s(href="http://localhost:4000/feed.json")
    end

    test "an excluded type advertises only the site-wide feed", %{conn: conn} do
      put_config(exclude: ["post"])
      post = published_post()

      html = response(get(conn, ~p"/blog/#{post.slug}"), 200)

      # Pages still syndicate, so the site-wide feed is still worth advertising.
      assert html =~ ~s(href="http://localhost:4000/feed.xml")
      refute html =~ ~s(href="http://localhost:4000/blog/feed.xml")
    end

    test "nothing is advertised when nothing syndicates", %{conn: conn} do
      post = published_post()
      put_config(exclude: ["post", "page"])

      html = response(get(conn, ~p"/blog/#{post.slug}"), 200)

      refute html =~ "application/atom+xml"
    end
  end

  describe "spec conformance" do
    test "the Atom feed carries the elements RFC 4287 requires", %{conn: conn} do
      published_post()

      body = response(get(conn, ~p"/feed.xml"), 200)

      # The declaration must be the very first byte, or a parser rejects it.
      assert String.starts_with?(body, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      # §4.1.1: an author on the feed covers every entry.
      assert body =~ "<author><name>"
      for required <- ["<id>", "<title>", "<updated>"], do: assert(body =~ required)
    end

    test "every JSON Feed item carries content, which 1.1 requires", %{conn: conn} do
      published_post()

      feed = Jason.decode!(response(get(conn, ~p"/feed.json"), 200))
      item = hd(feed["items"])

      # `summary` is a supplement to content in JSON Feed, not a substitute —
      # an item with neither renders empty in any reader that shows bodies.
      assert item["content_text"] || item["content_html"]
    end

    test "a control character in a title doesn't take the whole document down", %{conn: conn} do
      # XML 1.0 has no escape form for the C0 controls, so one pasted out of
      # Word makes the feed unparseable for every subscriber — all entries, not
      # just the offending one. They are dropped rather than escaped.
      published_post(%{title: "Bad\ftitle\vhere"})

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "Badtitlehere"
      refute String.contains?(body, "\f")
      refute String.contains?(body, "\v")
    end

    test "a quote in a title is escaped in attribute and element positions", %{conn: conn} do
      published_post(%{title: ~s(A "quoted" title)})

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "&quot;quoted&quot;"
    end
  end

  describe "bounds and config" do
    test "entry_limit caps the feed and is clamped to a ceiling" do
      Application.put_env(:kiln_cms, :feeds, entry_limit: 5)
      assert Feeds.entry_limit() == 5

      # A config typo must not make a feed serialize an entire archive.
      Application.put_env(:kiln_cms, :feeds, entry_limit: 10_000)
      assert Feeds.entry_limit() == 200

      Application.put_env(:kiln_cms, :feeds, entry_limit: "lots")
      assert Feeds.entry_limit() == 50
    end

    test "the feed carries no more than entry_limit entries", %{conn: conn} do
      Application.put_env(:kiln_cms, :feeds, entry_limit: 2)
      for _ <- 1..4, do: published_post()

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body |> String.split("<entry>") |> length() == 3
    end
  end

  describe "types without a public path segment" do
    test "a page appears in the site-wide feed", %{conn: conn} do
      n = System.unique_integer([:positive])
      Ash.Seed.seed!(Page, %{title: "About", slug: "feed-about-#{n}", state: :published})

      body = response(get(conn, ~p"/feed.xml"), 200)

      # Pages live at `<base>/<slug>` with no prefix, which is a perfectly good
      # feed link — an earlier draft dropped them from syndication entirely.
      assert body =~ ~s(href="http://localhost:4000/feed-about-#{n}")
    end

    test "its own feed lives under its plural, not at the site-wide URL", %{conn: conn} do
      n = System.unique_integer([:positive])
      Ash.Seed.seed!(Page, %{title: "About", slug: "feed-about-#{n}", state: :published})
      published_post()

      body = response(get(conn, "/pages/feed.xml"), 200)

      # `public_prefix/1` is "" for pages, so deriving the feed path from it
      # would put this document at `/feed.xml` — the site-wide feed's own URL.
      assert body =~ "feed-about-#{n}"
      assert body =~ "<title>KilnCMS — Page</title>"
      refute body =~ "/blog/"
    end
  end
end
