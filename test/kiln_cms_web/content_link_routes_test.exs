defmodule KilnCMSWeb.ContentLinkRoutesTest do
  @moduledoc """
  Workstream R8 of `docs/relationships-plan.md`: payload links (a
  `ContentLink` with no `field`) created, changed and deleted over
  `/api/json/content-links`, each authorized as an update of the link's
  source record (`KilnCMS.CMS.Checks.SourceUpdatable`).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "clr-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp key(owner, access \\ :read_write) do
    owner.id
    |> Accounts.mint_api_key!(
      "links",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: access},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "clr-#{System.unique_integer([:positive])}"

  defp req(method, path, key, body \\ nil, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)

    conn =
      if body,
        do: dispatch(conn, @endpoint, method, path, Jason.encode!(body)),
        else: dispatch(conn, @endpoint, method, path)

    {conn.status, if(conn.resp_body in [nil, ""], do: %{}, else: Jason.decode!(conn.resp_body))}
  end

  defp create_body(attrs), do: %{data: %{type: "content_link", attributes: attrs}}

  defp update_body(id, attrs), do: %{data: %{type: "content_link", id: id, attributes: attrs}}

  setup do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Source", slug: slug()}, actor: admin)
    post = CMS.create_post!(%{title: "Target", slug: slug()}, actor: admin)
    %{admin: admin, page: page, post: post}
  end

  test "an editor's read_write key creates, changes and deletes a payload link", ctx do
    key = key(user(:editor))

    assert {201, %{"data" => %{"id" => id, "attributes" => attrs}}} =
             req(
               :post,
               "/api/json/content-links",
               key,
               create_body(%{
                 source_id: ctx.page.id,
                 target_id: ctx.post.id,
                 label: "Main",
                 metadata: %{"quantity" => 2}
               })
             )

    assert attrs["kind"] == "related"
    assert attrs["field"] == nil
    assert attrs["source_type"] == "page"
    assert attrs["target_type"] == "post"
    assert attrs["metadata"] == %{"quantity" => 2}

    assert {200, %{"data" => %{"attributes" => %{"label" => "Side", "position" => 3}}}} =
             req(
               :patch,
               "/api/json/content-links/#{id}",
               key,
               update_body(id, %{label: "Side", position: 3})
             )

    assert {200, _} = req(:delete, "/api/json/content-links/#{id}", key)
    assert [] = CMS.list_backlinks!(ctx.post.id, actor: ctx.admin)
  end

  test "a read-only key may not write a link", ctx do
    assert {403, _} =
             req(
               :post,
               "/api/json/content-links",
               key(ctx.admin, :read),
               create_body(%{source_id: ctx.page.id, target_id: ctx.post.id})
             )
  end

  test "an editor who may not edit the source's type may not link from it", ctx do
    scoped = key(user(:editor, %{editable_types: ["post"]}))

    assert {403, _} =
             req(
               :post,
               "/api/json/content-links",
               scoped,
               create_body(%{source_id: ctx.page.id, target_id: ctx.post.id})
             )

    # The same editor may link from a post, whose type they can edit.
    assert {201, _} =
             req(
               :post,
               "/api/json/content-links",
               scoped,
               create_body(%{source_id: ctx.post.id, target_id: ctx.page.id})
             )

    link =
      CMS.create_payload_link!(%{source_id: ctx.page.id, target_id: ctx.post.id},
        actor: ctx.admin
      )

    assert {403, _} =
             req(
               :patch,
               "/api/json/content-links/#{link.id}",
               scoped,
               update_body(link.id, %{label: "x"})
             )

    assert {403, _} = req(:delete, "/api/json/content-links/#{link.id}", scoped)
  end

  test "ends that aren't content records of the site, or a self-link, are refused", ctx do
    key = key(ctx.admin)

    for attrs <- [
          %{source_id: ctx.page.id, target_id: Ash.UUID.generate()},
          %{source_id: Ash.UUID.generate(), target_id: ctx.post.id},
          %{source_id: ctx.page.id, target_id: ctx.page.id}
        ] do
      assert {status, %{"errors" => [_ | _]}} =
               req(:post, "/api/json/content-links", key, create_body(attrs))

      assert status in [400, 403]
    end
  end

  test "reference edges are written through their field, never here", ctx do
    key = key(ctx.admin)

    assert {400, _} =
             req(
               :post,
               "/api/json/content-links",
               key,
               create_body(%{source_id: ctx.page.id, target_id: ctx.post.id, kind: "reference"})
             )

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "featured",
        label: "Featured",
        field_type: :reference,
        target_type: "post"
      },
      actor: ctx.admin
    )

    CMS.update_page!(ctx.page, %{custom_fields: %{"featured" => ctx.post.id}}, actor: ctx.admin)
    [edge] = CMS.list_reference_links!(ctx.page.id, actor: ctx.admin)

    assert {400, _} =
             req(
               :patch,
               "/api/json/content-links/#{edge.id}",
               key,
               update_body(edge.id, %{metadata: %{"x" => 1}})
             )

    assert {400, _} = req(:delete, "/api/json/content-links/#{edge.id}", key)
    assert [_edge] = CMS.list_reference_links!(ctx.page.id, actor: ctx.admin)
  end

  test "an Idempotency-Key replays the create instead of linking twice", ctx do
    key = key(ctx.admin)
    body = create_body(%{source_id: ctx.page.id, target_id: ctx.post.id})

    first = req(:post, "/api/json/content-links", key, body, [{"idempotency-key", "link-1"}])
    second = req(:post, "/api/json/content-links", key, body, [{"idempotency-key", "link-1"}])

    assert {201, _} = first
    assert first == second
    assert [_one] = CMS.list_backlinks!(ctx.post.id, actor: ctx.admin)
  end
end
