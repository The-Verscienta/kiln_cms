defmodule KilnCMSWeb.ArtifactControllerTest do
  @moduledoc "Headless fired-artifact delivery (Kiln v2 — D9)."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "art-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "art-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Headless",
          slug: slug,
          blocks: [
            %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
            %{type: :image, data: %{"url" => "/p.png", "alt" => "pic"}, order: 1}
          ]
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    # Firing is async (#201): run the enqueued FireWorker so the artifact is
    # stored before the request, otherwise the API answers 503 (#208).
    KilnCMS.DataCase.drain_oban()
    slug
  end

  test "serves the json artifact for published content", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}") |> json_response(200)

    assert body["type"] == "page"
    assert body["title"] == "Headless"
    assert [%{"_type" => "heading"} | _] = body["blocks"]
  end

  test "includes CDN cache headers and honours If-None-Match (#188)", %{conn: conn} do
    slug = published_page()

    served = get(conn, ~p"/api/content/page/#{slug}")
    assert json_response(served, 200)
    assert ["public, max-age=300"] = get_resp_header(served, "cache-control")
    assert [etag] = get_resp_header(served, "etag")
    assert etag =~ ~r/^".+"$/
    assert [_last_modified] = get_resp_header(served, "last-modified")

    # Revalidating with the same ETag returns 304 with an empty body.
    not_modified =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/api/content/page/#{slug}")

    assert not_modified.status == 304
    assert not_modified.resp_body == ""
  end

  test "serves the json_ld surface as a schema.org graph", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}?surface=json_ld") |> json_response(200)

    assert body["@context"] == "https://schema.org"
    types = Enum.map(body["@graph"], & &1["@type"])
    # Pages fire a WebPage main node (#357, GEO).
    assert "WebPage" in types
    assert "ImageObject" in types
  end

  # #197: the artifact endpoint serves a specific locale via ?locale=.
  test "serves a locale-specific artifact via ?locale=", %{conn: conn} do
    actor = admin()
    slug = "art-loc-#{System.unique_integer([:positive])}"

    fr =
      CMS.create_page!(%{title: "Bonjour", slug: slug, locale: "fr"}, actor: actor)

    CMS.publish_page!(fr, actor: actor)
    KilnCMS.DataCase.drain_oban()

    body = conn |> get(~p"/api/content/page/#{slug}?locale=fr") |> json_response(200)
    assert body["title"] == "Bonjour"

    # The default locale has no such slug → 404.
    assert conn |> get(~p"/api/content/page/#{slug}?locale=en") |> json_response(404)
  end

  test "404s for unknown type, unknown slug, and unpublished content", %{conn: conn} do
    assert conn |> get(~p"/api/content/widget/whatever") |> json_response(404)
    assert conn |> get(~p"/api/content/page/does-not-exist") |> json_response(404)

    draft =
      CMS.create_page!(%{title: "Draft", slug: "art-draft-#{System.unique_integer([:positive])}"},
        actor: admin()
      )

    assert conn |> get(~p"/api/content/page/#{draft.slug}") |> json_response(404)
  end

  test "503s with Retry-After while a published artifact is still compiling", %{conn: conn} do
    actor = admin()
    slug = "art-bf-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(%{title: "Pending", slug: slug, blocks: []}, actor: actor)

    # Publish but do NOT drain — the FireWorker hasn't run, so no artifact yet.
    CMS.publish_page!(page, actor: actor)

    conn = get(conn, ~p"/api/content/page/#{slug}")

    assert %{"errors" => [%{"code" => "artifact_compiling", "status" => "503"}]} =
             json_response(conn, 503)

    assert ["2"] = get_resp_header(conn, "retry-after")

    # Once the background firing runs, the artifact is served.
    KilnCMS.DataCase.drain_oban()
    assert conn |> recycle() |> get(~p"/api/content/page/#{slug}") |> json_response(200)
  end
end
