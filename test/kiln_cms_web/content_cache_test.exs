defmodule KilnCMSWeb.ContentCacheTest do
  @moduledoc """
  Public delivery serves published content from the in-BEAM cache, and content
  writes invalidate it.
  """
  # async: false — relies on the shared content cache not being busted by other
  # concurrently-running tests.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Page

  setup do
    Cache.bust_published()
    :ok
  end

  defp published_page(title, extra \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: title, slug: "cc-#{System.unique_integer([:positive])}", state: :published},
        extra
      )
    )
  end

  # Raw DB delete (bypasses Ash), so the content cache is NOT busted — lets a
  # test prove a later response came from cache rather than the database.
  defp raw_delete(table, id) do
    Ecto.Adapters.SQL.query!(KilnCMS.Repo, "DELETE FROM #{table} WHERE id = $1", [
      Ecto.UUID.dump!(id)
    ])
  end

  test "a published page is served from cache (survives a raw DB delete)", %{conn: conn} do
    page = published_page("Cached Page")

    # First request populates the cache.
    assert conn |> get(~p"/#{page.slug}") |> html_response(200) =~ "Cached Page"

    # Delete the row directly, bypassing Ash (so the cache is NOT busted).
    raw_delete("pages", page.id)

    # Still served — proving the response came from cache, not the database.
    assert conn |> get(~p"/#{page.slug}") |> html_response(200) =~ "Cached Page"

    # After an explicit bust the now-missing row 404s.
    Cache.bust_published()
    assert conn |> get(~p"/#{page.slug}") |> response(404)
  end

  test "updating published content invalidates the cache", %{conn: conn} do
    page = published_page("Old Title")

    assert conn |> get(~p"/#{page.slug}") |> html_response(200) =~ "Old Title"

    {:ok, _} = CMS.update_page(page, %{title: "New Title"}, authorize?: false)

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)
    assert html =~ "New Title"
    refute html =~ "Old Title"
  end

  test "editing one page busts only its key, not the whole cache", %{conn: conn} do
    edited = published_page("Edited")
    other = published_page("Untouched")

    # Cache both pages.
    assert conn |> get(~p"/#{edited.slug}") |> html_response(200) =~ "Edited"
    assert conn |> get(~p"/#{other.slug}") |> html_response(200) =~ "Untouched"

    # Drop `other` from the DB without busting, so it's only reachable from cache.
    raw_delete("pages", other.id)

    # Editing `edited` must invalidate only its own key (per-key, not a clear).
    {:ok, _} = CMS.update_page(edited, %{title: "Edited New"}, authorize?: false)

    assert conn |> get(~p"/#{edited.slug}") |> html_response(200) =~ "Edited New"
    # `other` is still served from cache — proving its entry wasn't cleared.
    assert conn |> get(~p"/#{other.slug}") |> html_response(200) =~ "Untouched"
  end

  test "delivery cache hits carry resolved media URLs", %{conn: conn} do
    media =
      Ash.Seed.seed!(MediaItem, %{
        filename: "p.jpg",
        url: "/uploads/orig",
        content_type: "image/jpeg",
        width: 1600,
        height: 1067,
        alt: "A described image",
        variants: %{
          "thumb" => %{"key" => "t", "url" => "/uploads/thumb", "width" => 400, "height" => 267}
        }
      })

    page =
      published_page("Media Page", %{
        blocks: [
          %{type: :image, content: "/uploads/orig", data: %{"media_id" => media.id}, order: 0}
        ]
      })

    # First request resolves + caches the media-enriched blocks.
    assert conn |> get(~p"/#{page.slug}") |> html_response(200) =~ "/uploads/thumb 400w"

    # Drop the media row directly (no cache bust). A re-resolved request would now
    # find no media and omit the srcset.
    raw_delete("media_items", media.id)

    # The srcset is still present — proving resolved media URLs are cached, not
    # re-queried on every delivery hit.
    html = conn |> get(~p"/#{page.slug}") |> html_response(200)
    assert html =~ "/uploads/thumb 400w"
    assert html =~ ~s(alt="A described image")
  end

  test "published HTML carries CDN cache headers and supports conditional GET", %{conn: conn} do
    page = published_page("Cacheable")

    conn1 = get(conn, ~p"/#{page.slug}")
    assert html_response(conn1, 200) =~ "Cacheable"

    assert ["public, max-age=60, stale-while-revalidate=300"] =
             get_resp_header(conn1, "cache-control")

    assert [etag] = get_resp_header(conn1, "etag")
    assert ["Accept-Language"] = get_resp_header(conn1, "vary")

    # A conditional GET with the same ETag gets a 304 (no body).
    conn2 = conn |> put_req_header("if-none-match", etag) |> get(~p"/#{page.slug}")
    assert response(conn2, 304) == ""
  end

  test "a 404 for an unknown slug is not cacheable", %{conn: conn} do
    conn = get(conn, ~p"/no-such-slug-#{System.unique_integer([:positive])}")
    assert response(conn, 404)
    assert ["no-store"] = get_resp_header(conn, "cache-control")
  end

  test "delivery cache hits carry locale translations (no per-hit translations query)", %{
    conn: conn
  } do
    slug = "tr-#{System.unique_integer([:positive])}"
    en = published_page("EN page", %{slug: slug, locale: "en"})
    _fr = published_page("FR page", %{slug: slug, locale: "fr"})

    # First request (default locale) resolves + caches the translations list.
    html = conn |> get(~p"/#{en.slug}") |> html_response(200)
    assert html =~ ~s(hreflang="fr")

    # Drop the French variant directly (no cache bust). A re-resolved request would
    # now find no French translation and omit its hreflang alternate.
    raw_delete("pages", _fr.id)

    # The fr alternate is still present — proving translations are cached, not
    # re-queried on every delivery hit.
    assert conn |> get(~p"/#{en.slug}") |> html_response(200) =~ ~s(hreflang="fr")
  end
end
