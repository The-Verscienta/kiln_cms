defmodule KilnCMSWeb.AuthLocalePrefixTest do
  @moduledoc """
  A locale path prefix on a LiveView page reaches the page (#1699).

  `/es/sign-in` rendered `<html lang="en">` and English: `Plugs.SetLocale`
  strips the prefix in the endpoint, but `:restore_locale` reads the session.
  Worse, the prefixed URL could not connect at all — the LiveView join
  re-matches the browser's `/es/sign-in` against a router with no prefixed
  routes, is refused, and the client reloads the same URL. So
  `Plugs.LiveLocalePrefix` records the prefix as the session locale and
  redirects to the unprefixed path.

  The auth pages' form copy comes from AshAuthentication untranslated, so the
  translated string asserted is the root layout's skip link.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @skip_link %{
    "en" => "Skip to main content",
    "es" => "Saltar al contenido principal",
    "fr" => "Aller au contenu principal"
  }

  defp html_lang(html) do
    [_, lang] = Regex.run(~r/<html[^>]*\blang="([^"]*)"/, html)
    lang
  end

  for {prefixed, path, locale} <- [
        {"/es/sign-in", "/sign-in", "es"},
        {"/fr/register", "/register", "fr"},
        {"/es/reset", "/reset", "es"}
      ] do
    describe prefixed do
      test "redirects to #{path} with the prefix as the session locale", %{conn: conn} do
        conn = get(conn, unquote(prefixed))

        assert redirected_to(conn, 302) == unquote(path)
        assert get_session(conn, "locale") == unquote(locale)
      end

      test "then renders in #{locale}: lang attribute and translated copy", %{conn: conn} do
        conn = get(conn, unquote(prefixed))
        html = conn |> recycle() |> get(unquote(path)) |> html_response(200)

        assert html_lang(html) == unquote(locale)
        assert html =~ @skip_link[unquote(locale)]
        refute html =~ @skip_link["en"]
      end

      test "the LiveView connects and mounts in #{locale}", %{conn: conn} do
        assert {:error, {:redirect, %{to: unquote(path)}}} = live(conn, unquote(prefixed))

        {:ok, lv, _html} = conn |> get(unquote(prefixed)) |> recycle() |> live(unquote(path))

        assert :sys.get_state(lv.pid).socket.assigns.locale == unquote(locale)
      end
    end
  end

  test "the redirect keeps the query string", %{conn: conn} do
    conn = get(conn, "/es/sign-in?return_to=%2Feditor")
    assert redirected_to(conn, 302) == "/sign-in?return_to=%2Feditor"
  end

  test "every auth LiveView is reachable under a prefix", %{conn: conn} do
    paths =
      for route <- KilnCMSWeb.Router.__routes__(),
          {_view, _action, _opts, %{name: name}} <- [route.metadata[:phoenix_live_view]],
          to_string(name) =~ ~r/^auth_/,
          route.verb == :get,
          not String.contains?(route.path, ":"),
          do: route.path

    assert "/sign-in" in paths

    for path <- paths do
      assert redirected_to(get(conn, "/fr" <> path), 302) == path, "/fr#{path}"
    end
  end

  # The console's LiveViews are on `:browser`, not `:browser_auth`, and had the
  # same unjoinable URL.
  test "a console LiveView under a prefix redirects the same way", %{conn: conn} do
    conn = get(conn, "/fr/editor/calendar")

    assert redirected_to(conn, 302) == "/editor/calendar"
    assert get_session(conn, "locale") == "fr"
  end

  test "an unprefixed LiveView page keeps the session locale", %{conn: conn} do
    conn = conn |> init_test_session(%{"locale" => "fr"}) |> get("/sign-in")
    html = html_response(conn, 200)

    assert html_lang(html) == "fr"
    assert html =~ @skip_link["fr"]
    assert get_session(conn, "locale") == "fr"
  end

  test "a live navigation keeps the locale", %{conn: conn} do
    {:ok, lv, _html} = conn |> get("/es/sign-in") |> recycle() |> live("/sign-in")

    # The same patch the page's "Need an account?" link makes. That link is drawn
    # once per strategy, so a selector cannot click just one.
    render_patch(lv, "/register")
    assert_patch(lv, "/register")

    assert :sys.get_state(lv.pid).socket.assigns.locale == "es"
  end

  test "a controller page keeps its prefixed URL and leaves the session alone", %{conn: conn} do
    conn = conn |> init_test_session(%{"locale" => "fr"}) |> get("/es/developers")

    assert html_lang(html_response(conn, 200)) == "es"
    assert get_session(conn, "locale") == "fr"
  end

  # `/preview/:token/live` is a LiveView route with a segment the requester
  # chooses. A backslash in it makes `Phoenix.Controller.redirect/2` raise,
  # which would turn the page into a 500.
  test "a path with a backslash is served, not redirected", %{conn: conn} do
    conn = get(conn, "/fr/preview/a\\b/live")

    refute conn.status in [301, 302, 500]
  end
end
