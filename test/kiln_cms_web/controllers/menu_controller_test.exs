defmodule KilnCMSWeb.MenuControllerTest do
  @moduledoc """
  Navigation delivery (#466): `/api/menus` and `/api/menus/:key` serve resolved
  trees with live URLs, and never leak a link to content a reader can't see.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp uniq, do: System.unique_integer([:positive])

  defp menu(attrs \\ %{}) do
    CMS.create_menu!(
      Map.merge(%{key: "nav-#{uniq()}", name: "Main", locale: "en"}, attrs),
      authorize?: false
    )
  end

  defp item(menu, attrs) do
    CMS.create_menu_item!(Map.merge(%{menu_id: menu.id, label: "Item"}, attrs),
      authorize?: false
    )
  end

  defp page(state) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{title: "P", slug: "nav-#{uniq()}", state: state})
  end

  test "lists the site's menus", %{conn: conn} do
    m = menu(%{name: "Footer"})

    body = conn |> get(~p"/api/menus") |> json_response(200)

    assert Enum.any?(body["menus"], &(&1["key"] == m.key and &1["name"] == "Footer"))
  end

  test "serves a resolved tree with live URLs", %{conn: conn} do
    published = page(:published)
    m = menu()

    parent = item(m, %{label: "Section", link_type: :none, position: 0})

    item(m, %{
      label: "About",
      parent_id: parent.id,
      link_type: :content,
      target_type: "page",
      target_id: published.id
    })

    body = conn |> get(~p"/api/menus/#{m.key}") |> json_response(200)

    assert body["key"] == m.key
    assert [%{"label" => "Section", "children" => [child]}] = body["items"]
    assert child["label"] == "About"
    assert child["url"] == "/#{published.slug}"
  end

  test "omits items whose target isn't published", %{conn: conn} do
    m = menu()

    item(m, %{
      label: "Draft link",
      link_type: :content,
      target_type: "page",
      target_id: page(:draft).id
    })

    body = conn |> get(~p"/api/menus/#{m.key}") |> json_response(200)

    assert body["items"] == []
  end

  test "serves the requested locale variant, and 404s an unbuilt one", %{conn: conn} do
    key = "nav-#{uniq()}"
    menu(%{key: key, locale: "en", name: "Main"})
    fr = menu(%{key: key, locale: "fr", name: "Principal"})
    item(fr, %{label: "Accueil", link_type: :url, url: "/fr"})

    body = conn |> get(~p"/api/menus/#{key}?locale=fr") |> json_response(200)
    assert body["name"] == "Principal"
    assert [%{"label" => "Accueil"}] = body["items"]

    assert conn |> get(~p"/api/menus/#{key}?locale=es") |> json_response(404)
  end

  test "an unknown key 404s rather than serving an empty menu", %{conn: conn} do
    assert conn |> get(~p"/api/menus/does-not-exist") |> json_response(404)
  end

  # The locale is part of the URL, never a cookie — so a `public` cache entry
  # can't be poisoned by whichever signed-in editor happened to warm it.
  test "the response is shared-cacheable and keyed only by URL", %{conn: conn} do
    m = menu()
    conn = get(conn, ~p"/api/menus/#{m.key}")

    assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
    assert get_resp_header(conn, "vary") == []
  end

  test "a session locale never changes what a cacheable response serves", %{conn: conn} do
    key = "nav-#{uniq()}"
    menu(%{key: key, locale: "en", name: "Main"})
    menu(%{key: key, locale: "fr", name: "Principal"})

    body =
      conn
      |> Phoenix.ConnTest.init_test_session(%{"locale" => "fr"})
      |> get(~p"/api/menus/#{key}")
      |> json_response(200)

    assert body["name"] == "Main"
  end
end
