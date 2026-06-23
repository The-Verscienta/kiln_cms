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
  alias KilnCMS.CMS.Page

  setup do
    Cache.bust_published()
    :ok
  end

  defp published_page(title) do
    Ash.Seed.seed!(Page, %{
      title: title,
      slug: "cc-#{System.unique_integer([:positive])}",
      state: :published
    })
  end

  test "a published page is served from cache (survives a raw DB delete)", %{conn: conn} do
    page = published_page("Cached Page")

    # First request populates the cache.
    assert conn |> get(~p"/#{page.slug}") |> html_response(200) =~ "Cached Page"

    # Delete the row directly, bypassing Ash (so the cache is NOT busted).
    Ecto.Adapters.SQL.query!(KilnCMS.Repo, "DELETE FROM pages WHERE id = $1", [
      Ecto.UUID.dump!(page.id)
    ])

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
end
