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
    slug
  end

  test "serves the json artifact for published content", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}") |> json_response(200)

    assert body["type"] == "page"
    assert body["title"] == "Headless"
    assert [%{"_type" => "heading"} | _] = body["blocks"]
  end

  test "serves the json_ld surface as a schema.org graph", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}?surface=json_ld") |> json_response(200)

    assert body["@context"] == "https://schema.org"
    types = Enum.map(body["@graph"], & &1["@type"])
    assert "Article" in types
    assert "ImageObject" in types
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
end
