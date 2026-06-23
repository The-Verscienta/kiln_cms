defmodule KilnCMSWeb.PublicLocaleTest do
  @moduledoc """
  The public site localizes for anonymous visitors via session/Accept-Language
  (the path prefix still wins for content delivery).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.I18n

  describe "I18n.negotiate/1" do
    test "picks the best supported locale by q-value and primary subtag" do
      assert I18n.negotiate("fr-CA,fr;q=0.9,en;q=0.8") == "fr"
      assert I18n.negotiate("en-US,en;q=0.9") == "en"
      # Highest q wins regardless of order.
      assert I18n.negotiate("es;q=0.4,fr;q=0.9") == "fr"
      # Nothing supported.
      assert I18n.negotiate("de,nl;q=0.5") == nil
      assert I18n.negotiate(nil) == nil
      assert I18n.negotiate("") == nil
    end
  end

  describe "home page localization" do
    test "localizes via Accept-Language for anonymous visitors", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "fr-FR,fr;q=0.9,en;q=0.8")
        |> get(~p"/")
        |> html_response(200)

      # From priv/gettext/fr (home.html.heex hero).
      assert html =~ "Modélisez le contenu une fois"
      assert html =~ ~s(lang="fr")
    end

    test "defaults to English without a language preference", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "Model content once"
    end

    test "a session locale beats Accept-Language", %{conn: conn} do
      html =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "Modélisez le contenu une fois"
    end
  end

  describe "content delivery" do
    alias KilnCMS.CMS.Page

    test "an explicit /<locale>/ prefix wins over Accept-Language", %{conn: conn} do
      slug = "pl-#{System.unique_integer([:positive])}"
      Ash.Seed.seed!(Page, %{title: "About", slug: slug, locale: "en", state: :published})
      Ash.Seed.seed!(Page, %{title: "À propos", slug: slug, locale: "fr", state: :published})

      # Prefix says fr even though the browser asks for en.
      html =
        conn
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> get("/fr/#{slug}")
        |> html_response(200)

      assert html =~ "À propos"
    end
  end
end
