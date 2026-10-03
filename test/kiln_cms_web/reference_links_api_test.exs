defmodule KilnCMSWeb.ReferenceLinksApiTest do
  @moduledoc """
  Reference edges on the read API (#1594): additive. A `:reference` custom
  field still serializes its 1.0 snapshot, and its edge arrives through the
  existing `?include=content_links` / `incoming_links` with three new
  attributes (`field`, `source_type`, `target_type`). An anonymous reader is
  never handed an edge whose other end is a draft.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "refapi-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "refapi-#{System.unique_integer([:positive])}"

  defp api_get(path) do
    build_conn()
    |> put_req_header("accept", @accept)
    |> get(path)
    |> then(&{&1.status, Jason.decode!(&1.resp_body)})
  end

  setup do
    admin = admin()

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "hero",
        label: "Hero",
        field_type: :reference,
        target_type: "page"
      },
      actor: admin
    )

    page = CMS.create_page!(%{title: "Landing", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    %{admin: admin, page: page}
  end

  defp post!(admin, page, publish?) do
    post =
      CMS.create_post!(
        %{title: "Referrer", slug: slug(), custom_fields: %{"hero" => page.id}},
        actor: admin
      )

    if publish?, do: CMS.publish_post!(post, %{}, actor: admin), else: post
  end

  test "the snapshot is unchanged and the edge is an additive include", %{
    admin: admin,
    page: page
  } do
    post = post!(admin, page, true)

    assert {200, body} = api_get("/api/json/posts/#{post.id}?include=content_links")

    assert body["data"]["attributes"]["custom_fields"]["hero"] == %{
             "id" => page.id,
             "type" => "page",
             "slug" => page.slug,
             "title" => "Landing"
           }

    assert [%{"attributes" => link}] = body["included"]
    assert link["kind"] == "reference"
    assert link["field"] == "hero"
    assert link["source_type"] == "post"
    assert link["target_type"] == "page"
    assert link["target_id"] == page.id
  end

  test "incoming_links answers what links here, without the drafts", %{admin: admin, page: page} do
    published = post!(admin, page, true)
    _draft = post!(admin, page, false)

    assert {200, body} = api_get("/api/json/pages/#{page.id}?include=incoming_links")

    assert [%{"attributes" => link}] = body["included"]
    assert link["source_id"] == published.id
    assert link["field"] == "hero"
  end
end
