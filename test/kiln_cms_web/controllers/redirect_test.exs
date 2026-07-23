defmodule KilnCMSWeb.RedirectTest do
  @moduledoc """
  Automatic 301 redirects on published slug renames (the pathauto companion):
  renaming a published record's slug leaves a redirect at the old URL that
  resolves to the record's *current* path (no chains), draft renames leave
  nothing, unpublished targets stop resolving, and real content always beats
  a stale redirect.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  defp uniq, do: System.unique_integer([:positive])

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "rd-pg-#{uniq()}", state: :published}, attrs)
    )
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{
          title: "A post",
          slug: "rd-po-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp rename!(record, slug) do
    CMS.update_page!(record, %{slug: slug}, authorize?: false)
  end

  test "renaming a published page's slug 301s the old URL to the new one", %{conn: conn} do
    page = page(%{})
    old_slug = page.slug
    renamed = rename!(page, "rd-pg-#{uniq()}")

    conn = get(conn, "/#{old_slug}")
    assert redirected_to(conn, 301) == "/#{renamed.slug}"
  end

  test "two renames both 301 straight to the newest URL (no chains)", %{conn: conn} do
    page = page(%{})
    first = page.slug
    second = rename!(page, "rd-pg-#{uniq()}").slug
    final = rename!(CMS.get_page!(page.id, authorize?: false), "rd-pg-#{uniq()}").slug

    assert redirected_to(get(conn, "/#{first}"), 301) == "/#{final}"
    assert redirected_to(get(conn, "/#{second}"), 301) == "/#{final}"
  end

  test "a draft rename records no redirect", %{conn: conn} do
    page = page(%{state: :draft})
    old_slug = page.slug
    rename!(page, "rd-pg-#{uniq()}")

    assert conn |> get("/#{old_slug}") |> response(404)
  end

  test "a redirect stops resolving once its target is unpublished", %{conn: conn} do
    page = page(%{})
    old_slug = page.slug
    renamed = rename!(page, "rd-pg-#{uniq()}")
    CMS.unpublish_page!(renamed, %{}, authorize?: false)

    assert conn |> get("/#{old_slug}") |> response(404)
  end

  test "posts redirect under their /blog prefix", %{conn: conn} do
    post = post(%{})
    old_slug = post.slug
    renamed = CMS.update_post!(post, %{slug: "rd-po-#{uniq()}"}, authorize?: false)

    conn = get(conn, "/blog/#{old_slug}")
    assert redirected_to(conn, 301) == "/blog/#{renamed.slug}"
  end

  test "real content beats a stale redirect on the same path", %{conn: conn} do
    page = page(%{title: "Original"})
    old_slug = page.slug
    rename!(page, "rd-pg-#{uniq()}")

    # A new page claims the vacated slug — it must be served, not redirected.
    page(%{title: "Reclaimer", slug: old_slug, blocks: []})

    html = conn |> get("/#{old_slug}") |> html_response(200)
    assert html =~ "Reclaimer"
  end
end
