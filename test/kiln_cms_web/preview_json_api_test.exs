defmodule KilnCMSWeb.PreviewJsonApiTest do
  @moduledoc """
  A preview token on JSON:API (`KilnCMSWeb.Plugs.PreviewGrant`): the one draft
  it names joins the plain reads a headless front end already makes — by slug,
  by id, with its links included — and nothing else does. Published-only
  routes, other drafts and GraphQL are unchanged.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken

  @accept "application/vnd.api+json"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pvapi-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pvapi-#{System.unique_integer([:positive])}"

  defp api_get(path, opts \\ []) do
    conn = build_conn() |> put_req_header("accept", @accept)

    conn =
      case opts[:token] do
        nil -> conn
        token -> put_req_header(conn, "x-kiln-preview-token", token)
      end

    conn = get(conn, path)
    {conn, conn.status, Jason.decode!(conn.resp_body)}
  end

  defp expired_token(record) do
    Phoenix.Token.sign(
      KilnCMSWeb.Endpoint,
      "content preview",
      %{type: ContentTypes.type_name_for(record), id: record.id, org_id: record.org_id},
      signed_at: System.system_time(:second) - PreviewToken.max_age_seconds() - 1
    )
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
    draft = CMS.create_post!(%{title: "Draft", slug: slug()}, actor: admin)
    %{admin: admin, page: page, draft: draft, token: PreviewToken.sign(draft)}
  end

  test "the token reads its draft by slug on the plain index, with nothing else added", %{
    draft: draft,
    token: token
  } do
    {_conn, 200, %{"data" => []}} = api_get("/api/json/posts?filter[slug]=#{draft.slug}")

    {conn, 200, body} = api_get("/api/json/posts?filter[slug]=#{draft.slug}", token: token)

    assert [%{"id" => id, "attributes" => %{"title" => "Draft"}}] = body["data"]
    assert id == draft.id

    # A per-token answer: never stored by a shared cache, and keyed on the token.
    assert [cache_control] = get_resp_header(conn, "cache-control")
    refute cache_control =~ "public"
    assert conn |> get_resp_header("vary") |> Enum.join(",") =~ "x-kiln-preview-token"
  end

  test "an unfiltered index gains exactly the token's draft", %{admin: admin, token: token} do
    other_draft = CMS.create_post!(%{title: "Other draft", slug: slug()}, actor: admin)

    {_conn, 200, body} = api_get("/api/json/posts?page[limit]=100", token: token)
    ids = Enum.map(body["data"], & &1["id"])

    refute other_draft.id in ids
    assert Enum.count(body["data"], &(&1["attributes"]["title"] == "Draft")) == 1
  end

  test "the token reads its draft by id, but no other draft", %{
    admin: admin,
    draft: draft,
    token: token
  } do
    assert {_conn, 200, %{"data" => %{"id" => id}}} =
             api_get("/api/json/posts/#{draft.id}", token: token)

    assert id == draft.id

    other = CMS.create_post!(%{title: "Other", slug: slug()}, actor: admin)
    assert {_conn, 404, _} = api_get("/api/json/posts/#{other.id}", token: token)
  end

  test "the published-only routes never surface the draft", %{draft: draft, token: token} do
    {_conn, 200, body} =
      api_get("/api/json/posts/published?filter[slug]=#{draft.slug}", token: token)

    assert body["data"] == []
  end

  test "the draft's edge to a published document is included", %{
    admin: admin,
    page: page
  } do
    draft =
      CMS.create_post!(
        %{title: "Referrer", slug: slug(), custom_fields: %{"hero" => page.id}},
        actor: admin
      )

    path = "/api/json/posts/#{draft.id}?include=content_links"
    assert {_conn, 404, _} = api_get(path)

    {_conn, 200, body} = api_get(path, token: PreviewToken.sign(draft))

    assert [%{"attributes" => link}] = body["included"]
    assert link["source_id"] == draft.id
    assert link["target_id"] == page.id
  end

  test "an edge to another draft stays hidden", %{admin: admin} do
    hidden_page = CMS.create_page!(%{title: "Unpublished", slug: slug()}, actor: admin)

    draft =
      CMS.create_post!(
        %{title: "Referrer", slug: slug(), custom_fields: %{"hero" => hidden_page.id}},
        actor: admin
      )

    {_conn, 200, body} =
      api_get("/api/json/posts/#{draft.id}?include=content_links",
        token: PreviewToken.sign(draft)
      )

    assert Map.get(body, "included", []) == []
  end

  test "a published document's edge from the draft shows in its incoming links", %{
    admin: admin,
    page: page
  } do
    draft =
      CMS.create_post!(
        %{title: "Referrer", slug: slug(), custom_fields: %{"hero" => page.id}},
        actor: admin
      )

    path = "/api/json/pages/#{page.id}?include=incoming_links"
    {_conn, 200, anonymous} = api_get(path)
    assert Map.get(anonymous, "included", []) == []

    {_conn, 200, body} = api_get(path, token: PreviewToken.sign(draft))
    assert [%{"attributes" => %{"source_id" => source_id}}] = body["included"]
    assert source_id == draft.id
  end

  test "a sparse fieldset works under the token", %{draft: draft, token: token} do
    {_conn, 200, body} =
      api_get("/api/json/posts?filter[slug]=#{draft.slug}&fields[post]=title", token: token)

    assert [%{"attributes" => attributes}] = body["data"]
    assert Map.keys(attributes) == ["title"]
  end

  test "the token rides the query string too, and is consumed there", %{
    draft: draft,
    token: token
  } do
    {_conn, 200, body} =
      api_get("/api/json/posts?filter[slug]=#{draft.slug}&preview_token=#{token}")

    assert [%{"id" => id}] = body["data"]
    assert id == draft.id
  end

  test "an expired, tampered or garbage token is refused, not read anonymously", %{
    draft: draft
  } do
    for token <- [expired_token(draft), "garbage", PreviewToken.sign(draft) <> "x"] do
      assert {_conn, 404, %{"errors" => [%{"code" => "invalid_preview"}]}} =
               api_get("/api/json/posts?filter[slug]=#{draft.slug}", token: token)
    end
  end

  test "a token minted on another site is refused on this host" do
    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Org PV",
        slug: "pv-org-#{System.unique_integer([:positive])}",
        status: :active
      })

    post = CMS.create_post!(%{title: "Elsewhere", slug: slug()}, actor: admin(), tenant: org)

    assert {_conn, 404, %{"errors" => [%{"code" => "invalid_preview"}]}} =
             api_get("/api/json/posts/#{post.id}", token: PreviewToken.sign(post))
  end

  test "a token is never a write credential", %{draft: draft, token: token} do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("x-kiln-preview-token", token)
      |> patch("/api/json/posts/#{draft.id}", %{
        "data" => %{"type" => "post", "id" => draft.id, "attributes" => %{"title" => "Hijacked"}}
      })

    assert conn.status in [401, 403, 404]
    assert Ash.get!(KilnCMS.CMS.Post, draft.id, authorize?: false).title == "Draft"
  end

  test "GraphQL with the token header still cannot see the draft", %{
    draft: draft,
    token: token
  } do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-kiln-preview-token", token)
      |> post("/gql", %{"query" => ~s|{ getPost(id: "#{draft.id}") { id title } }|})

    body = Jason.decode!(conn.resp_body)
    refute get_in(body, ["data", "getPost", "title"]) == "Draft"
  end
end
