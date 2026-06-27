defmodule KilnCMSWeb.ContentI18nTest do
  @moduledoc """
  Locale-aware public delivery: a `/<locale>/…` prefix serves that locale, with
  fallback to the default locale, hreflang alternates, and a localized sitemap.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.I18n

  defp slug, do: "i18n-#{System.unique_integer([:positive])}"

  defp page(attrs) do
    Ash.Seed.seed!(Page, Map.merge(%{state: :published, locale: "en"}, attrs))
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{state: :published, locale: "en", published_at: DateTime.utc_now()},
        attrs
      )
    )
  end

  test "the default locale is served at the unprefixed URL", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})

    html = conn |> get(~p"/#{s}") |> html_response(200)
    assert html =~ "About"
    assert html =~ ~s(lang="en")
  end

  test "a locale prefix serves that locale's content", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})
    page(%{title: "À propos", slug: s, locale: "fr"})

    html = conn |> get("/fr/#{s}") |> html_response(200)
    assert html =~ "À propos"
    assert html =~ ~s(lang="fr")
    refute html =~ "About"
  end

  test "a missing locale falls back to the default locale's content", %{conn: conn} do
    s = slug()
    page(%{title: "Only English", slug: s, locale: "en"})

    # No :es variant exists, so the default (en) is served.
    html = conn |> get("/es/#{s}") |> html_response(200)
    assert html =~ "Only English"
  end

  test "hreflang alternates list every published locale plus x-default", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})
    page(%{title: "À propos", slug: s, locale: "fr"})

    html = conn |> get(~p"/#{s}") |> html_response(200)

    assert html =~ ~s(hreflang="en")
    assert html =~ ~s(hreflang="fr")
    assert html =~ ~s(hreflang="x-default")
    assert html =~ "/fr/#{s}"
  end

  test "an unsupported locale prefix is not a locale (404 via unknown type)", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})

    # "de" is not configured, so /de/<slug> is treated as type "de" → 404.
    assert conn |> get("/de/#{s}") |> response(404)
  end

  test "the sitemap lists each locale variant at its prefixed URL", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})
    page(%{title: "À propos", slug: s, locale: "fr"})

    xml = conn |> get(~p"/sitemap.xml") |> response(200)

    assert xml =~ "/#{s}</loc>"
    assert xml =~ "/fr/#{s}</loc>"
  end

  test "the UI chrome is localized via Gettext for a non-default locale", %{conn: conn} do
    s = slug()
    page(%{title: "À propos", slug: s, locale: "fr"})

    html = conn |> get("/fr/#{s}") |> html_response(200)

    # Translations from priv/gettext/fr.
    assert html =~ "Blogue"
    assert html =~ "Propulsé par KilnCMS."
    refute html =~ "Powered by KilnCMS."
  end

  test "a language switcher is shown when translations exist", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})
    page(%{title: "À propos", slug: s, locale: "fr"})

    html = conn |> get(~p"/#{s}") |> html_response(200)
    assert html =~ ~s(aria-label="Language")
  end

  test "no language switcher for single-locale content", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})

    html = conn |> get(~p"/#{s}") |> html_response(200)
    refute html =~ ~s(aria-label="Language")
  end

  # #146: internal public links must keep the active locale prefix.
  describe "locale-aware public links" do
    test "blog post links and the Blog nav keep the locale prefix on /fr/blog", %{conn: conn} do
      s = slug()
      post(%{title: "FR Post", slug: s, locale: "fr"})

      html = conn |> get("/fr/blog") |> html_response(200)

      # The post link is locale-prefixed, not the default unprefixed form.
      assert html =~ ~s(href="/fr/blog/#{s}")
      refute html =~ ~s(href="/blog/#{s}")
      # The header Blog nav link is prefixed too.
      assert html =~ ~s(href="/fr/blog")
    end

    test "default-locale blog links stay unprefixed", %{conn: conn} do
      s = slug()
      post(%{title: "EN Post", slug: s, locale: "en"})

      html = conn |> get("/blog") |> html_response(200)

      assert html =~ ~s(href="/blog/#{s}")
      refute html =~ ~s(href="/fr/blog/#{s}")
    end
  end

  # #175: a skip link is the first focusable element and targets <main id="main">.
  test "public pages render a skip link to main content", %{conn: conn} do
    s = slug()
    page(%{title: "About", slug: s, locale: "en"})

    html = conn |> get(~p"/#{s}") |> html_response(200)

    assert html =~ ~s(href="#main")
    assert html =~ "Skip to main content"
    # <main> carries the id="main" target (Phoenix may inject a phx-r debug attr).
    assert html =~ ~r/<main[^>]*\sid="main"/
  end

  describe "I18n.localized_path/2" do
    test "prefixes non-default locales but not the default or the home path" do
      assert I18n.localized_path("fr", "/blog") == "/fr/blog"
      assert I18n.localized_path("fr", "/blog/my-post") == "/fr/blog/my-post"
      assert I18n.localized_path("en", "/blog") == "/blog"
      assert I18n.localized_path("fr", "/") == "/"
      # Unknown/blank locale falls back to the unprefixed path.
      assert I18n.localized_path("zz", "/blog") == "/blog"
      assert I18n.localized_path(nil, "/blog") == "/blog"
    end
  end
end
