defmodule ShowcaseWeb.BlogLiveTest do
  @moduledoc "Smoke tests — the app renders even when KilnCMS is unreachable."
  use ShowcaseWeb.ConnCase, async: true

  test "GET / renders the blog page and nav", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "From the blog"
    assert html =~ "headless showcase"
  end

  test "shows a friendly error when KilnCMS can't be reached", %{conn: conn} do
    # config/test.exs points the client at a closed port.
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Couldn&#39;t reach KilnCMS" or html =~ "Couldn't reach KilnCMS"
  end

  test "search page mounts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/search")
    assert html =~ "Search"
  end

  test "contact page mounts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/contact")
    assert html =~ "Contact"
  end
end
