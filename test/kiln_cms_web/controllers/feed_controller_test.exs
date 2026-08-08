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

  # The resolved policy is cached per org (#719), so a config change mid-test
  # would otherwise be invisible for the whole TTL — the same clear the setup
  # block does, which is what these tests already rely on between them.
  defp put_config(opts) do
    Application.put_env(:kiln_cms, :feeds, opts)
    Cache.bust_published()
  end

  # This site's own settings row, the layer above the config.
  defp save_settings(attrs) do
    CMS.save_feed_settings!(attrs,
      actor: admin(),
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end

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

  describe "per-site syndication settings (#719)" do
    test "a site's own full-content choice overrides the deployment config", %{conn: conn} do
      # The config says summaries; this site says full text. Before #719 the
      # config was the only voice, and it was one voice for every tenant.
      put_config(full_content: [])
      save_settings(%{full_content_types: ["post"]})
      real_published_post("Body text here")

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ "<content type=\"html\">"
      assert body =~ "Body text here"
    end

    test "a site that says NO full content beats a config that turns it on", %{conn: conn} do
      # The scenario in the issue: an operator enabled `full_content: ["post"]`
      # for tenant A's newsletter, and B — which shares the compiled `post`
      # type — was handing complete articles to every anonymous scraper with no
      # way to opt out. An empty saved list is that opt-out, and it must not
      # collapse back into "unset".
      put_config(full_content: ["post"])
      save_settings(%{full_content_types: []})
      post = real_published_post("Body text here")

      body = response(get(conn, ~p"/feed.xml"), 200)

      refute body =~ "<content type=\"html\">"
      refute body =~ "Body text here"
      assert body =~ "<summary type=\"html\">#{post.excerpt}</summary>"
    end

    test "a site's own exclusion removes that type's feed route", %{conn: conn} do
      save_settings(%{excluded_types: ["post"]})
      post = published_post()

      assert response(get(conn, ~p"/blog/feed.xml"), 404)
      refute response(get(conn, ~p"/feed.xml"), 200) =~ post.slug
    end

    test "a site may syndicate a type the operator excluded deployment-wide", %{conn: conn} do
      put_config(exclude: ["post"])
      save_settings(%{excluded_types: []})
      post = published_post()

      assert response(get(conn, ~p"/blog/feed.xml"), 200) =~ post.slug
    end

    test "saving settings drops the cached feed rather than waiting out the TTL", %{conn: conn} do
      put_config(full_content: ["post"])
      post = real_published_post("Body text here")

      assert response(get(conn, ~p"/feed.xml"), 200) =~ "Body text here"

      # No cache bust of our own: the settings write must do it. Without that,
      # an admin turning full text OFF watches the feed keep handing out whole
      # articles for five more minutes with no way to tell whether it worked.
      save_settings(%{full_content_types: []})

      body = response(get(conn, ~p"/feed.xml"), 200)

      refute body =~ "Body text here"
      assert body =~ "<summary type=\"html\">#{post.excerpt}</summary>"
    end

    test "an excluded type stops being advertised on a delivery page", %{conn: conn} do
      save_settings(%{excluded_types: ["post"]})
      post = published_post()

      html = response(get(conn, ~p"/blog/#{post.slug}"), 200)

      assert html =~ ~s(href="http://localhost:4000/feed.xml")
      refute html =~ ~s(href="http://localhost:4000/blog/feed.xml")
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
      # Every *registered* type, not the core two by name. A downstream project
      # that registers its own content types on `:content_domains` still
      # syndicates them, so hardcoding ["post", "page"] leaves the site-wide
      # feed advertised and the assertion below fails for a reason that has
      # nothing to do with what this test is checking.
      put_config(exclude: Enum.map(KilnCMS.CMS.ContentTypes.all(), &to_string(&1.type)))

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

  # ── #720: taxonomy on entries, and feeds narrow enough to act on ───────────

  defp category(name) do
    n = System.unique_integer([:positive])

    CMS.create_category!(%{name: "#{name} #{n}", slug: "feed-cat-#{n}"}, actor: admin())
  end

  defp tag(name) do
    n = System.unique_integer([:positive])

    CMS.create_tag!(%{name: "#{name} #{n}", slug: "feed-tag-#{n}"}, actor: admin())
  end

  describe "entries carry their taxonomy" do
    test "Atom emits category term and label for the category and every tag", %{conn: conn} do
      cat = category("News")
      t = tag("Jazz")
      post = published_post()
      CMS.update_post!(post, %{category_id: cat.id, tag_ids: [t.id]}, actor: admin())
      Cache.bust_published()

      body = response(get(conn, ~p"/feed.xml"), 200)

      # `term` is the slug and `label` the name: a campaign tool that filtered on
      # a display name would break the day an editor renamed the tag.
      assert body =~ ~s(<category term="#{cat.slug}" label="#{cat.name}"/>)
      assert body =~ ~s(<category term="#{t.slug}" label="#{t.name}"/>)
    end

    test "JSON Feed emits a flat tags array of labels", %{conn: conn} do
      cat = category("News")
      post = published_post()
      CMS.update_post!(post, %{category_id: cat.id}, actor: admin())
      Cache.bust_published()

      body = Jason.decode!(response(get(conn, ~p"/feed.json"), 200))
      item = Enum.find(body["items"], &(&1["title"] == post.title))

      assert item["tags"] == [cat.name]
    end

    # `tags` is optional in JSON Feed 1.1, and an empty array in every item is
    # bytes on a route clients fetch on a timer.
    test "an untagged entry carries no tags key at all", %{conn: conn} do
      post = published_post()

      body = Jason.decode!(response(get(conn, ~p"/feed.json"), 200))
      item = Enum.find(body["items"], &(&1["title"] == post.title))

      refute Map.has_key?(item, "tags")
    end

    # The bound exists because this document is cached and served to everyone: a
    # hundred-tag record would otherwise put a hundred elements in front of every
    # subscriber.
    test "an absurdly tagged entry is capped", %{conn: conn} do
      tags = for _ <- 1..25, do: tag("Bulk")
      post = published_post()
      CMS.update_post!(post, %{tag_ids: Enum.map(tags, & &1.id)}, actor: admin())
      Cache.bust_published()

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body |> String.split("<category term=") |> length() == 21
    end
  end

  # The one invariant `FeedController` claims to own, and the reason it is
  # asserted on `filter/1` directly: the read policy ALSO filters
  # published-and-public, so deleting `audience: :public` from the controller
  # left every behavioural test green. The moduledoc says the filter "must not
  # depend on a policy staying shaped the way it is today" — this is what makes
  # that true.
  describe "the audience filter" do
    alias KilnCMSWeb.FeedController

    test "every scope filters to public, and to its own locale" do
      term = %{id: Ash.UUID.generate(), slug: "c", name: "C"}

      for scope <- [
            %{locale: "en", taxonomy: nil},
            %{locale: "fr", taxonomy: nil},
            %{locale: "en", taxonomy: {:category, term}},
            %{locale: "fr", taxonomy: {:tag, term}}
          ] do
        filter = FeedController.filter(scope)

        assert filter[:audience] == :public, "no audience filter for #{inspect(scope)}"
        assert filter[:locale] == scope.locale
      end
    end

    test "a gated record stays out of a segment feed too", %{conn: conn} do
      cat = category("News")
      gated = published_post(%{audience: :member, title: "Members only"})
      CMS.update_post!(gated, %{category_id: cat.id}, actor: admin())
      Cache.bust_published()

      body = response(get(conn, "/blog/category/#{cat.slug}/feed.xml"), 200)

      refute body =~ "Members only"
      refute body =~ gated.slug
    end
  end

  describe "segment feeds" do
    test "a category feed carries only that category", %{conn: conn} do
      cat = category("News")
      other = category("Sport")
      wanted = published_post()
      unwanted = published_post()
      CMS.update_post!(wanted, %{category_id: cat.id}, actor: admin())
      CMS.update_post!(unwanted, %{category_id: other.id}, actor: admin())
      Cache.bust_published()

      body = response(get(conn, "/blog/category/#{cat.slug}/feed.xml"), 200)

      assert body =~ wanted.title
      refute body =~ unwanted.title
      # Its own self link, not the type feed's — two documents, two ids.
      assert body =~ ~s(href="http://localhost:4000/blog/category/#{cat.slug}/feed.xml")
    end

    test "a tag feed carries only that tag", %{conn: conn} do
      t = tag("Jazz")
      wanted = published_post()
      unwanted = published_post()
      CMS.update_post!(wanted, %{tag_ids: [t.id]}, actor: admin())
      Cache.bust_published()

      body = Jason.decode!(response(get(conn, "/blog/tags/#{t.slug}/feed.json"), 200))
      titles = Enum.map(body["items"], & &1["title"])

      assert wanted.title in titles
      refute unwanted.title in titles
    end

    # 404 rather than an empty document, for the reason the type route gives: a
    # reader who subscribes to a mistyped category gets something that will never
    # have anything in it and no way to tell.
    test "an unknown category or tag is a 404", %{conn: conn} do
      assert response(get(conn, "/blog/category/no-such-thing/feed.xml"), 404)
      assert response(get(conn, "/blog/tags/no-such-thing/feed.json"), 404)
    end

    test "a segment feed on a type that does not syndicate is a 404", %{conn: conn} do
      cat = category("News")
      put_config(exclude: ["post"])

      assert response(get(conn, "/blog/category/#{cat.slug}/feed.xml"), 404)
    end

    test "the title names the segment", %{conn: conn} do
      cat = category("News")
      published_post()

      body = response(get(conn, "/blog/category/#{cat.slug}/feed.xml"), 200)

      assert body =~ "<title>KilnCMS — Post — #{cat.name}</title>"
    end
  end

  describe "locale feeds" do
    defp translated_post(locale) do
      n = System.unique_integer([:positive])

      Ash.Seed.seed!(Post, %{
        title: "Post #{locale} #{n}",
        slug: "feed-#{locale}-#{n}",
        excerpt: "Summary #{n}",
        locale: locale,
        state: :published,
        published_at: DateTime.utc_now()
      })
    end

    # The whole reason the unscoped feed filters to one locale: three
    # translations in one document re-notify every subscriber three times per
    # publish. Which left non-default-locale readers with nothing.
    test "the site-wide feed still carries the default locale only", %{conn: conn} do
      en = translated_post("en")
      fr = translated_post("fr")

      body = response(get(conn, ~p"/feed.xml"), 200)

      assert body =~ en.title
      refute body =~ fr.title
    end

    test "a locale feed carries that locale, and links its prefixed URLs", %{conn: conn} do
      en = translated_post("en")
      fr = translated_post("fr")

      body = response(get(conn, "/fr/feed.xml"), 200)

      assert body =~ fr.title
      refute body =~ en.title
      assert body =~ ~s(href="http://localhost:4000/fr/blog/#{fr.slug}")
      assert body =~ ~s(href="http://localhost:4000/fr/feed.xml")
    end

    # `record.locale` is a plain attribute on the struct the bust already
    # receives, so dropping the locale feed costs no read — which is why it is
    # NOT covered by the "cannot load relationships in an after_action" rule that
    # keeps the taxonomy segments on a TTL. Without this, a French publish never
    # invalidated the only feed its readers have.
    test "publishing a translation drops that locale's feed", %{conn: conn} do
      assert response(get(conn, "/fr/feed.xml"), 200)

      n = System.unique_integer([:positive])

      post =
        CMS.create_post!(
          %{title: "Nouveau #{n}", slug: "feed-pub-fr-#{n}", locale: "fr"},
          actor: admin()
        )

      CMS.publish_post!(post, actor: admin())
      KilnCMS.DataCase.drain_oban()

      assert response(get(build_conn(), "/fr/feed.xml"), 200) =~ "Nouveau #{n}"
    end

    test "JSON Feed declares the language", %{conn: conn} do
      translated_post("fr")

      assert Jason.decode!(response(get(conn, "/fr/feed.json"), 200))["language"] == "fr"
      assert Jason.decode!(response(get(conn, ~p"/feed.json"), 200))["language"] == "en"
    end

    # `/en/…` is stripped for the whole delivery site, not just here, so the
    # default-locale prefix resolves rather than 404ing. What matters is that it
    # does not become a SECOND thing to subscribe to: the self link is the
    # canonical `/feed.xml`, so both URLs carry one feed id.
    test "the default-locale prefix is the site-wide feed, under its canonical id",
         %{conn: conn} do
      post = published_post()
      body = response(get(conn, "/en/feed.xml"), 200)

      assert body =~ post.title
      assert body =~ ~s(<id>http://localhost:4000/feed.xml</id>)
      refute body =~ "/en/feed.xml"
    end

    # An unrecognised prefix is not stripped, so it reaches the type lookup as a
    # plural and 404s like any other unknown segment.
    test "an unconfigured locale is a 404", %{conn: conn} do
      assert response(get(conn, "/de/feed.xml"), 404)
    end

    test "a type feed still resolves under a locale prefix", %{conn: conn} do
      en = translated_post("en")
      fr = translated_post("fr")

      body = response(get(conn, "/fr/blog/feed.xml"), 200)

      assert body =~ fr.title
      refute body =~ en.title
      assert body =~ ~s(href="http://localhost:4000/fr/blog/feed.xml")
    end

    # A French reader on a French article was being pointed at the default-locale
    # feed, which carries no article they can read — while the feed that does is
    # one prefix away.
    test "a localized page advertises its own locale's feed", %{conn: conn} do
      fr = translated_post("fr")

      html = html_response(get(conn, "/fr/blog/#{fr.slug}"), 200)

      assert html =~ ~s(href="http://localhost:4000/fr/feed.xml")
      assert html =~ ~s(href="http://localhost:4000/fr/blog/feed.xml")
    end

    # The two axes compose, and they must both reach the cache key. Asserted by
    # fetching BOTH URLs in one test: an earlier version fetched only the scoped
    # one, which cannot detect a key collision at all — and the mutant that drops
    # the locale from the key survived it.
    test "a locale and a category compose, and do not share a key", %{conn: conn} do
      cat = category("News")
      fr = translated_post("fr")
      en = translated_post("en")
      CMS.update_post!(fr, %{category_id: cat.id}, actor: admin())
      CMS.update_post!(en, %{category_id: cat.id}, actor: admin())
      Cache.bust_published()

      french = response(get(conn, "/fr/blog/category/#{cat.slug}/feed.xml"), 200)
      english = response(get(build_conn(), "/blog/category/#{cat.slug}/feed.xml"), 200)

      assert french =~ fr.title
      refute french =~ en.title
      assert english =~ en.title
      refute english =~ fr.title
    end

    # A category and a tag can carry the SAME slug — they are different tables.
    # The key has to keep them apart, and the earlier tests always minted
    # distinct `feed-cat-N` / `feed-tag-N` slugs, so the mutant that dropped the
    # kind from the key survived.
    test "a category and a tag sharing a slug are different feeds", %{conn: conn} do
      shared = "shared-#{System.unique_integer([:positive])}"
      cat = CMS.create_category!(%{name: "Cat", slug: shared}, actor: admin())
      t = CMS.create_tag!(%{name: "Tag", slug: shared}, actor: admin())

      in_category = published_post()
      tagged = published_post()
      CMS.update_post!(in_category, %{category_id: cat.id}, actor: admin())
      CMS.update_post!(tagged, %{tag_ids: [t.id]}, actor: admin())
      Cache.bust_published()

      by_category = response(get(conn, "/blog/category/#{shared}/feed.xml"), 200)
      by_tag = response(get(build_conn(), "/blog/tags/#{shared}/feed.xml"), 200)

      assert by_category =~ in_category.title
      refute by_category =~ tagged.title
      assert by_tag =~ tagged.title
      refute by_tag =~ in_category.title
    end

    # Plug percent-decodes path segments, so `%2F` puts a literal `/` inside the
    # slug. With the key built by joining on `/`, a category slugged
    # `x/locale/fr` produced the SAME key as `/fr/blog/category/x/feed.xml` — two
    # different public documents, one key, and five minutes of whichever was
    # fetched first being served to everyone.
    #
    # Nothing validates taxonomy slugs today (#1044), so this is reachable by an
    # editor, not only by a request.
    test "a slug carrying a path separator cannot collide with another feed", %{conn: conn} do
      n = System.unique_integer([:positive])
      slug = "collide#{n}/locale/fr"
      cat = CMS.create_category!(%{name: "Collide", slug: slug}, actor: admin())

      english = published_post()
      french = translated_post("fr")
      CMS.update_post!(english, %{category_id: cat.id}, actor: admin())
      CMS.update_post!(french, %{category_id: cat.id}, actor: admin())
      Cache.bust_published()

      forged = response(get(conn, "/blog/category/collide#{n}%2Flocale%2Ffr/feed.xml"), 200)
      real = response(get(build_conn(), "/fr/blog/category/collide#{n}/feed.xml"), 404)

      # The forged URL is the category's real (ugly) slug, so it serves that
      # category's default-locale feed…
      assert forged =~ english.title
      refute forged =~ french.title
      # …and the other URL names a category that does not exist.
      assert real == ""

      # The advertised id must not carry the separator either.
      refute forged =~ "category/collide#{n}/locale/fr/feed.xml"
    end
  end
end
