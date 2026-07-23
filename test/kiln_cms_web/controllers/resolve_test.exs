defmodule KilnCMSWeb.ResolveTest do
  @moduledoc """
  `GET /api/resolve` — headless path resolution mirroring delivery semantics:
  published content answers "ok", a pathauto redirect answers "moved" with the
  record's current URL, everything else 404s. Bad input 400s.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  defp uniq, do: System.unique_integer([:positive])

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "rs-pg-#{uniq()}", state: :published}, attrs)
    )
  end

  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{
          title: "A post",
          slug: "rs-po-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp resolve(conn, path), do: get(conn, "/api/resolve?path=#{URI.encode_www_form(path)}")

  test "resolves a published page at the root", %{conn: conn} do
    page = page(%{})

    body = conn |> resolve("/#{page.slug}") |> json_response(200)

    assert %{"status" => "ok", "type" => "page", "slug" => slug, "id" => id} = body
    assert slug == page.slug
    assert id == page.id
  end

  test "resolves a published post under /blog", %{conn: conn} do
    post = post(%{})

    body = conn |> resolve("/blog/#{post.slug}") |> json_response(200)
    assert %{"status" => "ok", "type" => "post"} = body
  end

  test "reports a moved path after a published rename", %{conn: conn} do
    page = page(%{})
    old_slug = page.slug
    renamed = CMS.update_page!(page, %{slug: "rs-pg-#{uniq()}"}, authorize?: false)

    body = conn |> resolve("/#{old_slug}") |> json_response(200)

    assert %{"status" => "moved", "to" => to, "type" => "page", "id" => id} = body
    assert to == "/#{renamed.slug}"
    assert id == page.id
  end

  test "404s for drafts and unknown paths", %{conn: conn} do
    draft = page(%{state: :draft})

    assert conn |> resolve("/#{draft.slug}") |> json_response(404) == %{
             "status" => "not_found"
           }

    assert conn |> resolve("/no/such/deep/path") |> json_response(404)
  end

  test "rejects a path without a leading slash", %{conn: conn} do
    assert conn |> get("/api/resolve?path=blog/x") |> json_response(400)
    assert conn |> get("/api/resolve") |> json_response(400)
  end
end
