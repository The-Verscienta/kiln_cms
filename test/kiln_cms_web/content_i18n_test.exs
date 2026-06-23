defmodule KilnCMSWeb.ContentI18nTest do
  @moduledoc """
  Locale-aware public delivery: a `/<locale>/…` prefix serves that locale, with
  fallback to the default locale, hreflang alternates, and a localized sitemap.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS.Page

  defp slug, do: "i18n-#{System.unique_integer([:positive])}"

  defp page(attrs) do
    Ash.Seed.seed!(Page, Map.merge(%{state: :published, locale: "en"}, attrs))
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
end
