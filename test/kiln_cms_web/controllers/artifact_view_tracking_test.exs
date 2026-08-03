defmodule KilnCMSWeb.ArtifactViewTrackingTest do
  @moduledoc """
  A headless artifact fetch counts as a view. Without this a decoupled front end
  reports zero at `/editor/analytics` — the visitor's browser never touches
  Kiln, so `GET /api/content/:type/:slug` is the only delivery event there is.

  Counting is server-side (no beacon, no cookie) and, as ever, records only the
  aggregate counter — see `KilnCMSWeb.ViewTracking` for what a headless "view"
  does and does not mean.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Analytics
  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "avt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "avt-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Counted",
          slug: slug,
          blocks: [%{type: :heading, content: "Hi", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    page = CMS.publish_page!(page, actor: actor)
    # Firing is async (#201): store the artifact before the request, otherwise
    # the API answers 503 and nothing is delivered to count (#208).
    KilnCMS.DataCase.drain_oban()
    page
  end

  # The counter row for one document, or nil. `authorize?: false` because the
  # read policy is editor-only and this test has no actor.
  defp views(page) do
    Analytics.list_views!(authorize?: false)
    |> Enum.find(&(&1.content_id == page.id))
    |> case do
      nil -> nil
      row -> row.views
    end
  end

  test "fetching a published artifact records a view", %{conn: conn} do
    page = published_page()

    assert conn |> get(~p"/api/content/page/#{page.slug}") |> json_response(200)

    assert views(page) == 1
  end

  test "the per-day bucket is recorded alongside the all-time counter", %{conn: conn} do
    page = published_page()

    assert conn |> get(~p"/api/content/page/#{page.slug}") |> json_response(200)

    today = Date.utc_today()
    buckets = Analytics.views_since!(today, authorize?: false)

    assert Enum.any?(buckets, &(&1.content_id == page.id and &1.views == 1))
  end

  test "each surface fetch counts, so a 3-surface render counts three", %{conn: conn} do
    page = published_page()

    assert conn |> get(~p"/api/content/page/#{page.slug}?surface=json") |> json_response(200)
    assert conn |> get(~p"/api/content/page/#{page.slug}?surface=json_ld") |> json_response(200)
    assert conn |> get(~p"/api/content/page/#{page.slug}?surface=web") |> json_response(200)

    assert views(page) == 3
  end

  test "a revalidating client's 304 still counts", %{conn: conn} do
    page = published_page()

    served = get(conn, ~p"/api/content/page/#{page.slug}")
    assert json_response(served, 200)
    assert [etag] = get_resp_header(served, "etag")

    # A CDN or front end that revalidates instead of refetching is still
    # actively serving this document; excluding it would make a cache-fronted
    # site report near-zero, which is the gap this closes.
    revalidated =
      conn
      |> put_req_header("if-none-match", etag)
      |> get(~p"/api/content/page/#{page.slug}")

    assert response(revalidated, 304)
    assert views(page) == 2
  end

  test "a point-in-time snapshot does not count", %{conn: conn} do
    page = published_page()
    as_of = Date.utc_today() |> Date.to_iso8601()

    # `?as_of=` is a compliance read of what the document said on a date, not a
    # reader being served the live document.
    conn |> get(~p"/api/content/page/#{page.slug}?as_of=#{as_of}") |> json_response(200)

    assert views(page) == nil
  end

  test "an unresolvable slug counts nothing", %{conn: conn} do
    page = published_page()

    assert conn |> get(~p"/api/content/page/no-such-slug") |> json_response(404)

    assert views(page) == nil
  end
end
