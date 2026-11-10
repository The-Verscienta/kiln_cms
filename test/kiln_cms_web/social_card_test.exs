defmodule KilnCMSWeb.SocialCardTest do
  @moduledoc """
  The X (Twitter) Card and Open Graph tags (#2258).

  Both sets are read from one resolution, `KilnCMSWeb.Layouts.social_meta/1`,
  so the rendered tests assert they agree. The issue's "done when" is the
  helper every rendered test runs: each `og:` / `twitter:` tag appears at most
  once and never with an empty `content`.

  `async: false`: branding saves bust the shared Cachex table.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.CMS.StarterContent
  alias KilnCMSWeb.Layouts
  alias KilnCMSWeb.Tenant

  setup do
    org_id = Accounts.default_org_id()
    org = Accounts.get_organization!(org_id, authorize?: false)
    KilnCMS.Cache.bust_published()
    KilnCMS.Cache.bust_branding(org_id)
    on_exit(fn -> KilnCMS.Cache.bust_branding(org_id) end)

    %{org: org, org_id: org_id, actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "social-card-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp seed_org do
    org =
      Ash.Seed.seed!(Accounts.Organization, %{
        name: "Card Site",
        slug: "card-#{System.unique_integer([:positive])}",
        status: :active
      })

    on_exit(fn -> KilnCMS.Cache.bust_branding(org.id) end)
    org
  end

  defp brand!(org_id, attrs) do
    # authorize?: false — test setup; the admin-only write is covered by
    # `KilnCMSWeb.BrandingLiveTest`.
    CMS.save_site_branding!(attrs, authorize?: false, tenant: org_id)
    KilnCMS.Cache.bust_branding(org_id)
  end

  defp slug, do: "card-#{System.unique_integer([:positive])}"

  defp published_page(ctx, attrs) do
    page = CMS.create_page!(Map.merge(%{title: "A page", slug: slug()}, attrs), actor: ctx.actor)
    CMS.publish_page!(page, actor: ctx.actor)
  end

  defp published_post(ctx, attrs) do
    post = CMS.create_post!(Map.merge(%{title: "A post", slug: slug()}, attrs), actor: ctx.actor)
    CMS.publish_post!(post, %{}, actor: ctx.actor)
  end

  # Every og:/twitter: meta tag as `{key, content}`, in document order.
  defp social_tags(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(meta[property^="og:"], meta[name^="twitter:"]))
    |> Enum.map(fn tag ->
      key = List.first(Floki.attribute(tag, "property") ++ Floki.attribute(tag, "name"))
      {key, List.first(Floki.attribute(tag, "content"))}
    end)
  end

  defp json_ld_images(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(script[type="application/ld+json"]))
    |> Enum.flat_map(fn script ->
      script |> Floki.children() |> Enum.join() |> Jason.decode!() |> List.wrap()
    end)
    |> Enum.map(& &1["image"])
  end

  defp tag(html, key) do
    case for({^key, content} <- social_tags(html), do: content) do
      [] -> nil
      [content] -> content
    end
  end

  # The issue's "no duplicate or empty tags". `og:locale:alternate` is one tag
  # per other locale by design.
  defp assert_clean_card(html) do
    tags = Enum.reject(social_tags(html), fn {key, _} -> key == "og:locale:alternate" end)

    for {key, content} <- tags do
      assert is_binary(content) and String.trim(content) != "", "#{key} has a blank content"
    end

    keys = Enum.map(tags, &elem(&1, 0))
    assert keys == Enum.uniq(keys), "duplicate social tags: #{inspect(keys -- Enum.uniq(keys))}"

    html
  end

  describe "a content page" do
    test "a post with its own SEO fields fills the whole card from them", ctx do
      post =
        published_post(ctx, %{
          seo_title: "Card title",
          seo_description: "Card description.",
          seo_image: "https://cdn.test/card.png"
        })

      html =
        build_conn() |> get("/blog/#{post.slug}") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:card") == "summary_large_image"
      assert tag(html, "twitter:title") == "Card title"
      assert tag(html, "twitter:description") == "Card description."
      assert tag(html, "twitter:image") == "https://cdn.test/card.png"

      # The two sets are one resolution, so they cannot disagree.
      assert tag(html, "og:title") == tag(html, "twitter:title")
      assert tag(html, "og:description") == tag(html, "twitter:description")
      assert tag(html, "og:image") == tag(html, "twitter:image")
    end

    test "a relative seo_image is advertised absolute, on the site's own host", ctx do
      page = published_page(ctx, %{seo_image: "/uploads/relative.png"})

      html = build_conn() |> get("/#{page.slug}") |> html_response(200) |> assert_clean_card()

      expected = Tenant.base_url(ctx.org) <> "/uploads/relative.png"
      assert tag(html, "og:image") == expected
      assert tag(html, "twitter:image") == expected
      assert tag(html, "twitter:card") == "summary_large_image"
      # The JSON-LD image is the same absolute URL.
      assert expected in json_ld_images(html)
    end

    test "no image anywhere is a summary card with no image or description tags", ctx do
      brand!(ctx.org_id, %{social_image_url: nil})
      page = published_page(ctx, %{title: "Bare page"})

      html = build_conn() |> get("/#{page.slug}") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:card") == "summary"
      assert tag(html, "twitter:title") == "Bare page"
      assert tag(html, "og:title") == "Bare page"
      assert tag(html, "og:image") == nil
      assert tag(html, "twitter:image") == nil
      assert tag(html, "twitter:description") == nil
      assert tag(html, "og:description") == nil
    end
  end

  describe "the blog index" do
    test "carries its title and description, as a summary card without a brand image", ctx do
      brand!(ctx.org_id, %{social_image_url: nil})

      html = build_conn() |> get("/blog") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:title") == "Blog"
      assert tag(html, "twitter:description") == "Latest posts."
      assert tag(html, "og:title") == "Blog"
      assert tag(html, "twitter:card") == "summary"
    end

    test "follows the brand image into a large card", ctx do
      brand!(ctx.org_id, %{social_image_url: "/uploads/brand.png"})

      html = build_conn() |> get("/blog") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:card") == "summary_large_image"
      assert tag(html, "twitter:image") == Tenant.base_url(ctx.org) <> "/uploads/brand.png"
    end
  end

  describe "the home page" do
    test "the stock home is titled with the site name", ctx do
      refute StarterContent.published_home?(ctx.org_id)
      brand!(ctx.org_id, %{site_name: "Acme Docs"})

      html = build_conn() |> get("/") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:title") == "Acme Docs"
      assert tag(html, "og:title") == "Acme Docs"
      assert tag(html, "twitter:card") in ["summary", "summary_large_image"]
    end

    test "a published Home page brings its own title", ctx do
      published_page(ctx, %{title: "Welcome home", slug: StarterContent.home_slug()})

      html = build_conn() |> get("/") |> html_response(200) |> assert_clean_card()

      assert tag(html, "twitter:title") == "Welcome home"
      assert tag(html, "og:title") == "Welcome home"
    end
  end

  describe "gated renders" do
    test "an audience-gated post's teaser carries the full card, image absolute", ctx do
      post =
        published_post(ctx, %{
          audience: hd(Audiences.gated()),
          seo_title: "Members piece",
          seo_description: "For members.",
          seo_image: "/uploads/gated.png"
        })

      html =
        build_conn() |> get("/blog/#{post.slug}") |> html_response(200) |> assert_clean_card()

      expected = Tenant.base_url(ctx.org) <> "/uploads/gated.png"
      assert tag(html, "twitter:card") == "summary_large_image"
      assert tag(html, "twitter:title") == "Members piece"
      assert tag(html, "twitter:description") == "For members."
      assert tag(html, "twitter:image") == expected
      assert tag(html, "og:image") == expected
    end

    test "a passphrase lock page carries the full card, image absolute", ctx do
      page =
        published_page(ctx, %{
          access_password: "let me in please",
          seo_title: "Locked piece",
          seo_image: "/uploads/locked.png"
        })

      html = build_conn() |> get("/#{page.slug}") |> html_response(401) |> assert_clean_card()

      assert tag(html, "twitter:card") == "summary_large_image"
      assert tag(html, "twitter:title") == "Locked piece"
      assert tag(html, "twitter:image") == Tenant.base_url(ctx.org) <> "/uploads/locked.png"
    end
  end

  describe "twitter:site" do
    test "appears once on a content page, the blog index and the stock home", ctx do
      brand!(ctx.org_id, %{twitter_site: "kilncms"})
      post = published_post(ctx, %{})

      for path <- ["/blog/#{post.slug}", "/blog", "/"] do
        html = build_conn() |> get(path) |> html_response(200) |> assert_clean_card()
        assert tag(html, "twitter:site") == "@kilncms", "no twitter:site on #{path}"
      end
    end

    test "is absent when the site has none", ctx do
      post = published_post(ctx, %{})

      for path <- ["/blog/#{post.slug}", "/blog", "/"] do
        html = build_conn() |> get(path) |> html_response(200)
        assert tag(html, "twitter:site") == nil
      end
    end

    test "never carries another site's handle", ctx do
      other = seed_org()
      brand!(other.id, %{twitter_site: "@othersite"})

      html = build_conn() |> get("/blog") |> html_response(200)
      assert tag(html, "twitter:site") == nil
      refute html =~ "@othersite"

      brand!(ctx.org_id, %{twitter_site: "@defaultsite"})

      other_html = build_conn() |> org_conn(other) |> get("/") |> html_response(200)
      assert tag(other_html, "twitter:site") == "@othersite"
      refute other_html =~ "@defaultsite"
    end
  end

  describe "social_meta/1" do
    test "a blank page image falls through to the brand image", ctx do
      brand!(ctx.org_id, %{social_image_url: "/uploads/brand.png"})

      meta = Layouts.social_meta(%{current_org: ctx.org, og_image: "  "})

      assert meta.image == Tenant.base_url(ctx.org) <> "/uploads/brand.png"
      assert meta.card == "summary_large_image"
    end

    test "blank title and description resolve to the site name and nil", ctx do
      brand!(ctx.org_id, %{site_name: "Acme Docs"})

      meta = Layouts.social_meta(%{current_org: ctx.org, page_title: " ", meta_description: ""})

      assert meta.title == "Acme Docs"
      assert meta.description == nil
      assert meta.image == nil
      assert meta.card == "summary"
    end

    test "a missing current_org key resolves no brand image or handle", ctx do
      brand!(ctx.org_id, %{social_image_url: "/uploads/brand.png", twitter_site: "@kilncms"})

      meta = Layouts.social_meta(%{og_image: "/uploads/page.png"})

      # The relative page image has no host to go on, so it is dropped rather
      # than guessed (#560's fail-closed rule).
      assert meta.image == nil
      assert meta.site == nil
      assert meta.card == "summary"

      assert Layouts.social_meta(%{og_image: "https://cdn.test/page.png"}).image ==
               "https://cdn.test/page.png"
    end

    test "a nil current_org resolves no handle even when the default org has one", ctx do
      # A pre-router error page renders with a nil org; resolving it would
      # put the default org's account on a host that may be another site's.
      brand!(ctx.org_id, %{social_image_url: "/uploads/brand.png", twitter_site: "@kilncms"})

      meta = Layouts.social_meta(%{current_org: nil})

      assert meta.site == nil
      assert meta.image == nil
    end
  end

  describe "Tenant.absolute_url/2" do
    test "prefixes a site path with the org's own base URL", ctx do
      other = seed_org()

      assert Tenant.absolute_url(ctx.org, "/uploads/x.png") ==
               Tenant.base_url(ctx.org) <> "/uploads/x.png"

      assert Tenant.absolute_url(other.id, " /uploads/x.png ") ==
               Tenant.base_url(other) <> "/uploads/x.png"
    end

    test "passes an absolute http(s) URL through, trimmed", ctx do
      assert Tenant.absolute_url(ctx.org, " https://cdn.test/x.png ") == "https://cdn.test/x.png"
      assert Tenant.absolute_url(nil, "http://cdn.test/x.png") == "http://cdn.test/x.png"
    end

    test "returns nil for blanks, a nil org with a path, and anything else", ctx do
      assert Tenant.absolute_url(ctx.org, nil) == nil
      assert Tenant.absolute_url(ctx.org, "  ") == nil
      assert Tenant.absolute_url(nil, "/uploads/x.png") == nil
      assert Tenant.absolute_url(ctx.org, "//evil.example/x.png") == nil
      assert Tenant.absolute_url(ctx.org, "javascript:alert(1)") == nil
      assert Tenant.absolute_url(ctx.org, "uploads/x.png") == nil
    end
  end
end
