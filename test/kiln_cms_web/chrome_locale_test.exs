defmodule KilnCMSWeb.ChromeLocaleTest do
  @moduledoc """
  The public site's chrome follows the reader, and the reader is the URL
  (#2595).

  Two rules, tested together because each one alone was the bug:

    * a public, shared-cacheable response takes its language from the URL
      only, the path prefix or the site's default, never the session. Before,
      an unprefixed URL fetched with a French session cookie was answered in
      French and marked `public, max-age=60`, so a CDN handed that French copy
      to every anonymous visitor of the URL;
    * on a fallback page (`/fr/x` answered by an English record) the chrome,
      `<html lang>` and `Content-Language` are the reader's, French; the
      article is the record's and says so with `<article lang>`, and
      `x-kiln-locale` names it.
  """
  # async: false — the delivery payload, branding, menus and fallback chains
  # all live in the shared Cachex, which `setup` clears.
  use KilnCMSWeb.ConnCase, async: false

  # Publishing logs that it stores unsigned provenance in test.
  @moduletag :capture_log

  import KilnCMS.FormFixtures, only: [form!: 2]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @passphrase "open sesame please"

  setup %{conn: conn} do
    KilnCMS.Cache.bust_published()
    org = KilnCMS.OrgFixtures.org("chrome")
    admin = admin()

    on_exit(fn ->
      KilnCMS.Cache.bust_branding(org.id)
      KilnCMS.Cache.bump_menus_generation(org.id)
      KilnCMS.Cache.bust_locale_fallbacks(org.id)
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end)

    %{conn: org_conn(conn, org), org: org, admin: admin}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "chrome-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(org, attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          org_id: org.id,
          title: "Chrome page",
          slug: "chrome-#{uniq()}",
          locale: "en",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp french(conn), do: Phoenix.ConnTest.init_test_session(conn, %{"locale" => "fr"})

  # A fresh conn on the same site, so one request's cookies never reach the next.
  defp fresh(%{org: org}), do: org_conn(build_conn(), org)

  defp doc(html), do: LazyHTML.from_document(html)

  defp attr(html, selector, name) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp html_lang(html), do: html |> attr("html", "lang") |> hd()

  defp header(conn, name), do: get_resp_header(conn, name)

  # A header menu `key` per locale, chosen by branding.
  defp header_menu!(%{org: org, admin: admin}, labels) do
    for {locale, label} <- labels do
      menu =
        CMS.create_menu!(%{key: "main", name: "Main", locale: locale}, actor: admin, tenant: org)

      CMS.create_menu_item!(
        %{menu_id: menu.id, label: label, position: 0, link_type: :url, url: "/#{locale}-menu"},
        actor: admin,
        tenant: org
      )
    end

    CMS.save_site_branding!(%{header_menu_key: "main"}, actor: admin, tenant: org)
    KilnCMS.Cache.bust_branding(org.id)
    KilnCMS.Cache.bump_menus_generation(org.id)
  end

  defp chains!(%{org: org, admin: admin}, fallbacks) do
    CMS.save_site_locale_settings!(%{fallbacks: fallbacks}, actor: admin, tenant: org)
    KilnCMS.Cache.bust_locale_fallbacks(org.id)
  end

  # What may differ between two renders of one public URL for two visitors:
  # the per-session CSRF token in the root layout (a follow-up, out of this
  # change's scope), per-request nonces and a form's signed fill-time token.
  # Everything else must be identical.
  defp normalize(body) do
    body
    |> String.replace(~r/name="_kiln_rendered_at" value="[^"]*"/, ~s(name="_kiln_rendered_at"))
    |> String.replace(~r/name="csrf-token" content="[^"]*"/, ~s(name="csrf-token"))
    |> String.replace(~r/content="[^"]*" name="csrf-token"/, ~s(name="csrf-token"))
    |> String.replace(~r/nonce="[^"]*"/, ~s(nonce=""))
    |> String.replace(~r/id="phx-[^"]*"/, ~s(id="phx"))
  end

  # The first difference, with context, rather than two whole pages.
  defp assert_same_body(left, right, label) do
    left = normalize(left)
    right = normalize(right)

    if left != right do
      at = :binary.longest_common_prefix([left, right])
      from = max(at - 120, 0)

      flunk("""
      #{label}: bodies differ at byte #{at}
      with session: #{binary_part(left, from, min(240, byte_size(left) - from))}
      without:      #{binary_part(right, from, min(240, byte_size(right) - from))}
      """)
    end
  end

  describe "an unprefixed URL with a French session" do
    test "is answered in the default locale, as it is without a session", ctx do
      p = page(ctx.org, %{title: "Plain English"})
      anonymous = get(fresh(ctx), "/#{p.slug}")
      with_session = ctx |> fresh() |> french() |> get("/#{p.slug}")

      html = html_response(with_session, 200)
      assert html_lang(html) == "en"
      assert attr(html, "article.public-article", "lang") == ["en"]
      assert html =~ ~r/>\s*Blog\s*</
      refute html =~ "Blogue"
      assert header(with_session, "content-language") == ["en"]
      assert header(with_session, "x-kiln-locale") == ["en"]
      assert [cache_control] = header(with_session, "cache-control")
      assert cache_control =~ "public"

      assert header(with_session, "etag") == header(anonymous, "etag")
      assert_same_body(html, html_response(anonymous, 200), "/#{p.slug}")
    end

    test "does not serve the French record either", ctx do
      # That record was reachable at `/x` only through the session: the same
      # leak, one layer down. Its URL is `/fr/x`.
      p = page(ctx.org, %{title: "Seulement en français", locale: "fr"})

      assert ctx |> fresh() |> french() |> get("/#{p.slug}") |> html_response(404)
      assert ctx |> fresh() |> get("/fr/#{p.slug}") |> html_response(200) =~ "Seulement"
    end

    test "the blog index, search and the stock home are in the default locale", ctx do
      for path <- ["/blog", "/search", "/"] do
        html = ctx |> fresh() |> french() |> get(path) |> html_response(200)

        assert html_lang(html) == "en", path
        refute html =~ "Blogue", path
      end
    end

    test "a form's page and its embed post to the default locale's prefix", ctx do
      form = form!(%{}, actor: ctx.admin, tenant: ctx.org.id)

      for path <- ["/forms/#{form.slug}", "/forms/#{form.slug}/embed"] do
        html = ctx |> fresh() |> french() |> get(path) |> html_response(200)

        assert html_lang(html) == "en", path
        assert html =~ ~r/>\s*Submit\s*</, path
        refute html =~ "Soumettre", path
        assert attr(html, "form.kiln-form", "action") == ["/en/forms/#{form.slug}"], path
      end
    end

    test "a refusal posted from the unprefixed form page is in English", ctx do
      form = form!(%{}, actor: ctx.admin, tenant: ctx.org.id)
      page_html = ctx |> fresh() |> french() |> get("/forms/#{form.slug}") |> html_response(200)
      [action] = attr(page_html, "form.kiln-form", "action")

      html =
        ctx
        |> fresh()
        |> french()
        |> Map.put(:remote_ip, {10, 25, 95, rem(uniq(), 250) + 1})
        |> post(action, %{"email" => "nope"})
        |> html_response(422)

      assert html =~ "There is a problem with your submission"
      refute html =~ "Votre envoi comporte un problème"
    end
  end

  describe "the header's brand link (#2636)" do
    defp brand_href(html), do: html |> attr("header.public-header .public-measure > a", "href")

    test "keeps the reader's prefix and lands on a French stock home", ctx do
      p = page(ctx.org, %{title: "Only in English"})

      html = ctx |> fresh() |> get("/fr/#{p.slug}") |> html_response(200)
      assert brand_href(html) == ["/fr/home"]

      # No published Home page: the stock template, in the URL's locale.
      home = ctx |> fresh() |> get("/fr/home") |> html_response(200)
      assert html_lang(home) == "fr"
      assert home =~ ~s(id="home-features")
      assert home =~ "Blogue"
      assert brand_href(home) == ["/fr/home"]
    end

    test "lands on the published Home page when the site has one", ctx do
      page(ctx.org, %{title: "Accueil du site", slug: "home", locale: "fr"})

      home = ctx |> fresh() |> get("/fr/home") |> html_response(200)
      assert html_lang(home) == "fr"
      assert home =~ "Accueil du site"
      refute home =~ ~s(id="home-features")
    end

    test "the path is / for the default locale and /<locale>/home otherwise" do
      assert KilnCMSWeb.Layouts.public_home_path(nil) == "/"
      assert KilnCMSWeb.Layouts.public_home_path("en") == "/"
      assert KilnCMSWeb.Layouts.public_home_path("xx") == "/"
      assert KilnCMSWeb.Layouts.public_home_path("fr") == "/fr/home"
    end

    test "is the site root on a default-locale page", ctx do
      p = page(ctx.org, %{})

      for path <- ["/#{p.slug}", "/", "/en/#{p.slug}"] do
        html = ctx |> fresh() |> get(path) |> html_response(200)
        assert brand_href(html) == ["/"], path
      end
    end
  end

  describe "a regional locale with no catalog of its own (#2637)" do
    setup do
      original = Application.get_env(:kiln_cms, :i18n)
      locales = Keyword.fetch!(original, :locales) ++ ["fr-CA"]
      Application.put_env(:kiln_cms, :i18n, Keyword.put(original, :locales, locales))
      on_exit(fn -> Application.put_env(:kiln_cms, :i18n, original) end)
    end

    test "translates through its language's catalog" do
      refute "fr-CA" in Gettext.known_locales(KilnCMSWeb.Gettext)

      Gettext.with_locale(KilnCMSWeb.Gettext, "fr-CA", fn ->
        assert Gettext.gettext(KilnCMSWeb.Gettext, "Blog") == "Blogue"

        assert Gettext.ngettext(
                 KilnCMSWeb.Gettext,
                 "%{count} a11y issue",
                 "%{count} a11y issues",
                 2
               ) == "2 problèmes d'accessibilité"

        # A message no catalog has is still its English msgid.
        assert Gettext.gettext(KilnCMSWeb.Gettext, "No such message #2637") ==
                 "No such message #2637"
      end)
    end

    test "wears French chrome under <html lang=\"fr-CA\">", ctx do
      p = page(ctx.org, %{title: "Only in English"})

      for path <- ["/fr-CA/#{p.slug}", "/fr-CA/blog", "/fr-CA/home"] do
        conn = ctx |> fresh() |> get(path)
        html = html_response(conn, 200)

        assert html_lang(html) == "fr-CA", path
        assert html =~ "Blogue", path
        refute html =~ ~r/>\s*Blog\s*</, path
      end

      # The record page names the reader's language on the response too.
      conn = ctx |> fresh() |> get("/fr-CA/#{p.slug}")
      assert header(conn, "content-language") == ["fr-CA"]
    end
  end

  describe "a fallback page (/fr/x answered by an English record)" do
    setup ctx do
      header_menu!(ctx, [{"en", "Pricing"}, {"fr", "Tarifs"}])
      %{page: page(ctx.org, %{title: "Only in English"})}
    end

    test "wears French chrome around an English article", ctx do
      conn = get(fresh(ctx), "/fr/#{ctx.page.slug}")
      html = html_response(conn, 200)

      assert html_lang(html) == "fr"
      assert attr(html, "article.public-article", "lang") == ["en"]
      assert html =~ "Only in English"

      assert header(conn, "content-language") == ["fr"]
      assert header(conn, "x-kiln-locale") == ["en"]

      # The menus are the reader's.
      assert html =~ "Tarifs"
      refute html =~ "Pricing"
      assert html =~ ~s(aria-label="Langue")

      # The machine-facing description stays with the record.
      assert attr(html, ~s(meta[property="og:locale"]), "content") == ["en"]
      [canonical] = attr(html, ~s(link[rel="canonical"]), "href")
      assert String.ends_with?(canonical, "/#{ctx.page.slug}")
      refute canonical =~ "/fr/"
    end

    test "the stock header links keep the reader's prefix", ctx do
      # No configured header menu here: the stock Blog and Search links.
      CMS.save_site_branding!(%{header_menu_key: nil}, actor: ctx.admin, tenant: ctx.org)
      KilnCMS.Cache.bust_branding(ctx.org.id)

      html = ctx |> fresh() |> get("/fr/#{ctx.page.slug}") |> html_response(200)

      assert html =~ ~s(href="/fr/blog")
      assert html =~ ~s(href="/fr/search")
      assert html =~ "Blogue"
    end

    test "a form on the article stays in the article's language", ctx do
      form = form!(%{}, actor: ctx.admin, tenant: ctx.org.id)
      p = page(ctx.org, %{blocks: [%{"_type" => "form", "form_slug" => form.slug}]})

      html = ctx |> fresh() |> get("/fr/#{p.slug}") |> html_response(200)

      assert html_lang(html) == "fr"
      assert attr(html, "form.kiln-form", "action") == ["/en/forms/#{form.slug}"]
      form_text = html |> doc() |> LazyHTML.query("form.kiln-form") |> LazyHTML.text()
      assert form_text =~ "Submit"
      refute form_text =~ "Soumettre"
    end

    test "/fr/x and /x never share a validator", ctx do
      fr = get(fresh(ctx), "/fr/#{ctx.page.slug}")
      en = get(fresh(ctx), "/#{ctx.page.slug}")

      [fr_etag] = header(fr, "etag")
      [en_etag] = header(en, "etag")
      refute fr_etag == en_etag

      # A validator from the French URL never 304s the English one...
      mismatched =
        ctx |> fresh() |> put_req_header("if-none-match", fr_etag) |> get("/#{ctx.page.slug}")

      assert mismatched.status == 200
      assert html_lang(mismatched.resp_body) == "en"

      # ...and its own 304 names both languages, as the 200 does.
      hit =
        ctx
        |> fresh()
        |> put_req_header("if-none-match", fr_etag)
        |> get("/fr/#{ctx.page.slug}")

      assert hit.status == 304
      assert header(hit, "content-language") == ["fr"]
      assert header(hit, "x-kiln-locale") == ["en"]
    end
  end

  test "a chain fallback (es → fr) names both languages", ctx do
    chains!(ctx, %{"es" => ["fr"]})
    s = "chrome-chain-#{uniq()}"
    page(ctx.org, %{slug: s, title: "fr page", locale: "fr"})
    page(ctx.org, %{slug: s, title: "en page", locale: "en"})

    conn = get(fresh(ctx), "/es/#{s}")
    html = html_response(conn, 200)

    assert html =~ "fr page"
    assert html_lang(html) == "es"
    assert attr(html, "article.public-article", "lang") == ["fr"]
    assert header(conn, "content-language") == ["es"]
    assert header(conn, "x-kiln-locale") == ["fr"]
    assert attr(html, ~s(meta[property="og:locale"]), "content") == ["fr"]
  end

  test "a page in the reader's own language names it once, everywhere", ctx do
    p = page(ctx.org, %{title: "En français", locale: "fr"})

    conn = get(fresh(ctx), "/fr/#{p.slug}")
    html = html_response(conn, 200)

    assert html_lang(html) == "fr"
    assert attr(html, "article.public-article", "lang") == ["fr"]
    assert header(conn, "content-language") == ["fr"]
    assert header(conn, "x-kiln-locale") == ["fr"]
  end

  # The whole rule as a table: the URL decides the chrome, the session never.
  test "the chrome's language is a function of the URL alone", ctx do
    p = page(ctx.org, %{title: "Table"})

    for {path, chrome} <- [{"/#{p.slug}", "en"}, {"/fr/#{p.slug}", "fr"}, {"/es/#{p.slug}", "es"}],
        session <- [nil, "fr", "es", "en"] do
      conn = fresh(ctx)
      conn = if session, do: init_test_session(conn, %{"locale" => session}), else: conn
      conn = get(conn, path)
      html = html_response(conn, 200)

      label = "#{path} with session #{inspect(session)}"
      assert html_lang(html) == chrome, label
      assert header(conn, "content-language") == [chrome], label
      assert header(conn, "x-kiln-locale") == ["en"], label
      assert attr(html, "article.public-article", "lang") == ["en"], label
    end
  end

  # The guard (#2595): every public-cacheable route answers a French session
  # exactly as it answers no session at all. A controller that forgets
  # `Plugs.UrlLocale` fails here, whichever of its routes it is.
  describe "every public-cacheable delivery route" do
    setup ctx do
      p = page(ctx.org, %{title: "Guard page"})
      form = form!(%{}, actor: ctx.admin, tenant: ctx.org.id)

      td =
        CMS.create_type_definition!(
          %{
            name: "gig#{uniq()}",
            label: "Gigs",
            plural_label: "gigs",
            path_segment: "gigs#{uniq()}"
          },
          actor: ctx.admin,
          tenant: ctx.org
        )

      CMS.create_field_definition!(
        %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
        actor: ctx.admin,
        tenant: ctx.org
      )

      paths =
        for prefix <- ["", "/fr"],
            path <- [
              "/#{p.slug}",
              "/blog",
              "/forms/#{form.slug}",
              "/forms/#{form.slug}/embed",
              "/#{td.path_segment}",
              "/#{td.path_segment}/index.json"
            ],
            do: prefix <> path

      %{paths: ["/" | paths]}
    end

    test "answers a French session as it answers none", ctx do
      for path <- ctx.paths do
        anonymous = get(fresh(ctx), path)
        with_session = ctx |> fresh() |> french() |> get(path)

        assert anonymous.status == 200, path
        assert with_session.status == anonymous.status, path
        assert header(with_session, "etag") == header(anonymous, "etag"), path

        assert header(with_session, "content-language") == header(anonymous, "content-language"),
               path

        assert_same_body(with_session.resp_body, anonymous.resp_body, path)
      end
    end

    test "the event index's JSON names the URL's language", ctx do
      json_paths = Enum.filter(ctx.paths, &String.ends_with?(&1, "/index.json"))

      for path <- json_paths do
        expected = if String.starts_with?(path, "/fr/"), do: "fr", else: "en"
        body = ctx |> fresh() |> french() |> get(path) |> json_response(200)
        assert body["language"] == expected, path
      end
    end
  end

  describe "the lock page" do
    # The default site: a passphrase page goes through the real create and
    # publish actions, as `ContentLockTest` makes them.
    setup %{admin: admin} do
      page =
        CMS.create_page!(
          %{title: "Locked English", slug: "chrome-lock-#{uniq()}", access_password: @passphrase},
          actor: admin
        )

      CMS.publish_page!(page, actor: admin)
      KilnCMS.DataCase.drain_oban()
      %{locked: page}
    end

    test "under /fr/ wears French chrome and posts under /fr/", %{locked: page} do
      conn = get(build_conn(), "/fr/#{page.slug}")
      html = html_response(conn, 401)

      assert html_lang(html) == "fr"
      assert html =~ "Cette page nécessite une phrase secrète"
      assert attr(html, "h1.public-title", "lang") == ["en"]
      assert header(conn, "content-language") == ["fr"]
      assert header(conn, "x-kiln-locale") == ["en"]
      assert attr(html, "form", "action") |> Enum.member?("/fr/_unlock")
    end

    test "an unprefixed lock page ignores a French session", %{locked: page} do
      html = build_conn() |> french() |> get("/#{page.slug}") |> html_response(401)

      assert html_lang(html) == "en"
      assert html =~ "This page needs a passphrase"
      assert attr(html, "form", "action") |> Enum.member?("/en/_unlock")
    end

    test "unlocking under /fr/ returns to /fr/", %{locked: page} do
      conn = unlock(build_conn(), "/fr/_unlock", page, @passphrase)

      assert redirected_to(conn, 303) == "/fr/#{page.slug}"
    end

    test "a wrong passphrase under /fr/ re-renders in French", %{locked: page} do
      html = build_conn() |> unlock("/fr/_unlock", page, "wrong") |> html_response(401)

      assert html_lang(html) == "fr"
      assert html =~ "Cette phrase secrète n&#39;a pas fonctionné"
    end
  end

  test "the paywall wears the reader's chrome around the document's words", %{admin: admin} do
    {:ok, post} =
      CMS.create_post(
        %{
          title: "Gated English",
          slug: "chrome-gated-#{uniq()}",
          excerpt: "The teaser sentence.",
          audience: hd(KilnCMS.CMS.Audiences.gated())
        },
        actor: admin
      )

    {:ok, post} = CMS.publish_post(post, %{}, actor: admin)

    conn = get(build_conn(), "/fr/blog/#{post.slug}")
    html = html_response(conn, 200)

    assert html_lang(html) == "fr"
    assert html =~ "Réservé aux membres"
    assert attr(html, "h1.public-title", "lang") == ["en"]
    assert header(conn, "content-language") == ["fr"]
    assert header(conn, "x-kiln-locale") == ["en"]
  end

  # The session-following surfaces keep following it: only public delivery
  # changed.
  test "the sign-in screen still follows the session's locale" do
    html = build_conn() |> french() |> get("/sign-in") |> html_response(200)

    assert html_lang(html) == "fr"
  end

  defp unlock(conn, action, page, passphrase) do
    post(conn, action, %{
      "path" => "/#{page.slug}",
      "type" => "page",
      "locale" => page.locale,
      "passphrase" => passphrase
    })
  end
end
