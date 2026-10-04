defmodule KilnCMSWeb.ArtifactPreviewTest do
  @moduledoc """
  `GET /api/content/:type/:slug` with a preview token: the one draft it names,
  rendered live from its working copy for any surface — what a headless front
  end's draft mode renders in its own templates. Per-token, uncounted, and
  refused for any other document.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.TypedFixtures

  alias KilnCMS.Analytics
  alias KilnCMS.CMS
  alias KilnCMS.CMS.PreviewToken

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "apv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "apv-#{System.unique_integer([:positive])}"

  defp draft_page(actor, heading \\ "Draft heading") do
    CMS.create_page!(
      %{
        title: "Draft title",
        slug: slug(),
        blocks:
          typed_blocks([%{type: :heading, content: heading, data: %{"level" => 2}, order: 0}])
      },
      actor: actor
    )
  end

  defp preview(conn, type, slug, token, params \\ %{}) do
    conn
    |> put_req_header("x-kiln-preview-token", token)
    |> get("/api/content/#{type}/#{slug}", params)
  end

  defp assert_invalid_preview(conn) do
    assert %{"errors" => [%{"code" => "invalid_preview"}]} = json_response(conn, 404)
  end

  test "a draft has no artifact without a token, and renders live with one", %{conn: conn} do
    page = draft_page(admin())

    assert build_conn() |> get(~p"/api/content/page/#{page.slug}") |> json_response(404)

    conn = preview(conn, "page", page.slug, PreviewToken.sign(page), %{"surface" => "web"})

    assert %{"html" => html} = json_response(conn, 200)
    assert html =~ "Draft heading"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "etag") == []
  end

  test "the json surface is the plain artifact, with no stega annotation", %{conn: conn} do
    page = draft_page(admin())

    body =
      conn
      |> preview("page", page.slug, PreviewToken.sign(page), %{"surface" => "json"})
      |> json_response(200)

    assert body["title"] == "Draft title"
    refute body |> Jason.encode!() |> String.match?(~r/[\x{E0000}-\x{E007F}]/u)
  end

  test "a published document's pending edits are what the token shows", %{conn: conn} do
    actor = admin()
    page = actor |> draft_page() |> then(&CMS.publish_page!(&1, actor: actor))
    KilnCMS.DataCase.drain_oban()

    Ash.Seed.update!(page, %{
      working_title: "Pending title",
      working_blocks: page.blocks,
      working_copy_at: DateTime.utc_now()
    })

    preview_body =
      conn
      |> preview("page", page.slug, PreviewToken.sign(page), %{"surface" => "json"})
      |> json_response(200)

    assert preview_body["title"] == "Pending title"

    # Readers still get the published artifact.
    assert %{"title" => "Draft title"} =
             build_conn() |> get(~p"/api/content/page/#{page.slug}") |> json_response(200)
  end

  test "a preview is not counted as a view", %{conn: conn} do
    page = draft_page(admin())

    assert conn |> preview("page", page.slug, PreviewToken.sign(page)) |> json_response(200)

    refute Enum.any?(Analytics.list_views!(authorize?: false), &(&1.content_id == page.id))
  end

  test "another slug, type or locale under the token is refused", %{conn: conn} do
    actor = admin()
    mine = draft_page(actor)
    theirs = draft_page(actor)
    token = PreviewToken.sign(mine)

    assert_invalid_preview(preview(conn, "page", theirs.slug, token))
    assert_invalid_preview(preview(build_conn(), "post", mine.slug, token))
    assert_invalid_preview(preview(build_conn(), "page", mine.slug, token, %{"locale" => "zz"}))
    assert_invalid_preview(preview(build_conn(), "page", mine.slug, token, %{"surface" => "nope"}))
  end

  test "an expired or garbage token is refused rather than served the published page", %{
    conn: conn
  } do
    actor = admin()
    page = actor |> draft_page() |> then(&CMS.publish_page!(&1, actor: actor))
    KilnCMS.DataCase.drain_oban()

    assert_invalid_preview(preview(conn, "page", page.slug, "garbage"))
  end

  test "as_of does not combine with a token", %{conn: conn} do
    page = draft_page(admin())

    conn =
      preview(conn, "page", page.slug, PreviewToken.sign(page), %{
        "as_of" => "2026-01-01T00:00:00Z"
      })

    assert json_response(conn, 400)
  end
end
