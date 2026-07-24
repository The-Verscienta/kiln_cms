defmodule KilnCMSWeb.PathAliasTest do
  @moduledoc """
  Multi-segment path aliases (#485): the alias serves as the canonical URL
  (any depth, via the delivery fallback), the flat slug URL 301s to it, alias
  changes/removals on published content leave redirects, the resolve endpoint
  mirrors delivery, and the `path` calculation + sitemap prefer the alias.
  Validation rejects malformed, reserved, and colliding aliases.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp uniq, do: System.unique_integer([:positive])

  defp published_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "Aliased page",
          slug: "pa-#{uniq()}",
          state: :published,
          blocks: [%{type: :heading, content: "Alias Body Heading", order: 0}]
        },
        attrs
      )
    )
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "alias-admin-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "a deep alias serves the record and the flat URL 301s to it", %{conn: conn} do
    n = uniq()
    alias_path = "/acupuncture/needle/size/#{n}mm"
    page = published_page(%{path_alias: alias_path})

    html = conn |> get(alias_path) |> html_response(200)
    assert html =~ "Alias Body Heading"

    assert redirected_to(get(conn, "/#{page.slug}"), 301) == alias_path
  end

  test "a two-segment alias works through the generic route's fallback", %{conn: conn} do
    n = uniq()
    alias_path = "/kiln/care-#{n}"
    published_page(%{path_alias: alias_path})

    assert conn |> get(alias_path) |> html_response(200) =~ "Alias Body Heading"
  end

  test "changing a published alias leaves a 301; removing it restores the flat URL",
       %{conn: conn} do
    n = uniq()
    old_alias = "/guides/old-#{n}"
    new_alias = "/guides/new-#{n}"
    page = published_page(%{path_alias: old_alias})

    CMS.update_page!(page, %{path_alias: new_alias}, authorize?: false)
    assert redirected_to(get(conn, old_alias), 301) == new_alias

    CMS.update_page!(
      CMS.get_page!(page.id, authorize?: false),
      %{path_alias: nil},
      authorize?: false
    )

    assert redirected_to(get(conn, new_alias), 301) == "/#{page.slug}"
    assert conn |> get("/#{page.slug}") |> html_response(200)
  end

  test "the resolve endpoint mirrors delivery", %{conn: conn} do
    n = uniq()
    alias_path = "/catalog/deep/item-#{n}"
    page = published_page(%{path_alias: alias_path})

    flat =
      conn
      |> get("/api/resolve?path=#{URI.encode_www_form("/" <> page.slug)}")
      |> json_response(200)

    assert %{"status" => "moved", "to" => ^alias_path} = flat

    aliased =
      conn |> get("/api/resolve?path=#{URI.encode_www_form(alias_path)}") |> json_response(200)

    assert %{"status" => "ok", "slug" => slug} = aliased
    assert slug == page.slug
  end

  # The sitemap's alias handling lives in sitemap_controller_test (async:
  # false — the sitemap XML is served from the shared cache).
  test "the path calculation prefers the alias" do
    n = uniq()
    alias_path = "/library/shelf/book-#{n}"
    page = published_page(%{path_alias: alias_path})

    assert CMS.get_page!(page.id, load: [:path], authorize?: false).path == alias_path
  end

  test "validation rejects malformed, reserved, and colliding aliases" do
    actor = admin()
    page = CMS.create_page!(%{title: "Alias Valid #{uniq()}"}, actor: actor)

    for bad <- ["no-slash", "/Upper/Case", "/trailing/", "/editor/hidden"] do
      assert {:error, _} = CMS.update_page(page, %{path_alias: bad}, actor: actor)
    end

    taken = "/taken/spot-#{uniq()}"
    published_page(%{path_alias: taken})
    assert {:error, _} = CMS.update_page(page, %{path_alias: taken}, actor: actor)

    ok = "/fine/place-#{uniq()}"
    assert CMS.update_page!(page, %{path_alias: ok}, actor: actor).path_alias == ok
  end
end
