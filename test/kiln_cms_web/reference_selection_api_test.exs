defmodule KilnCMSWeb.ReferenceSelectionApiTest do
  @moduledoc """
  A reference field's `selection` (#2285) through the headless surfaces: a
  JSON:API `PATCH` and a GraphQL mutation both end in `ApplyCustomFields`, so a
  filtered-out target is refused with the field error shape they already return
  for an unresolvable one, and `GET /api/schema` describes the selection.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @schema KilnCMSWeb.GraphqlSchema

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rsa-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "selection",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp api_patch(post, key, custom_fields) do
    body = %{data: %{type: "post", id: post.id, attributes: %{custom_fields: custom_fields}}}

    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> dispatch(@endpoint, :patch, "/api/json/posts/#{post.id}", Jason.encode!(body))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @add """
  mutation ($id: ID!, $field: String!, $targets: [ReferenceTargetInput!]!) {
    addPostReferences(id: $id, field: $field, targets: $targets) {
      result { id }
      errors { message code fields }
    }
  }
  """

  setup do
    admin = user(:admin)
    editor = user(:editor)
    slug = fn -> "rsa-#{System.unique_integer([:positive])}" end

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "linked_#{System.unique_integer([:positive])}",
          label: "Linked",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          selection: %{"states" => ["published"]}
        },
        actor: admin
      )

    live = CMS.create_page!(%{title: "Live", slug: slug.()}, actor: admin)
    live = CMS.publish_page!(live, %{}, actor: admin)
    draft = CMS.create_page!(%{title: "Only a draft", slug: slug.()}, actor: admin)
    post = CMS.create_post!(%{title: "Source", slug: slug.()}, actor: editor)

    %{admin: admin, editor: editor, field: field, live: live, draft: draft, post: post}
  end

  test "JSON:API PATCH adds a matching target and refuses a filtered-out one", ctx do
    key = key(ctx.editor)
    name = ctx.field.name

    assert {200, _body} = api_patch(ctx.post, key, %{name => [ctx.live.id]})

    post = CMS.get_post!(ctx.post.id, authorize?: false)

    assert {status, body} = api_patch(post, key, %{name => [ctx.live.id, ctx.draft.id]})
    assert status in [400, 422]

    assert [%{"detail" => detail} | _] = body["errors"]
    assert detail =~ "“Only a draft” isn't one of the records this field accepts."

    saved = CMS.get_post!(ctx.post.id, authorize?: false)
    assert Enum.map(saved.custom_fields[name], & &1["id"]) == [ctx.live.id]
  end

  test "owner self through an API key is the key's user: their pages only", ctx do
    CMS.update_field_definition!(ctx.field, %{selection: %{"owner" => "self"}}, actor: ctx.admin)

    mine =
      CMS.create_page!(%{title: "Mine", slug: "rsa-m-#{System.unique_integer([:positive])}"},
        actor: ctx.editor
      )

    key = key(ctx.editor)

    assert {200, _} = api_patch(ctx.post, key, %{ctx.field.name => [mine.id]})

    post = CMS.get_post!(ctx.post.id, authorize?: false)
    assert {status, body} = api_patch(post, key, %{ctx.field.name => [mine.id, ctx.live.id]})
    assert status in [400, 422]
    assert hd(body["errors"])["detail"] =~ "“Live” isn't one of the records"
  end

  test "a GraphQL mutation refuses it with the same message", ctx do
    run = fn targets ->
      Absinthe.run(@add, @schema,
        variables: %{
          "id" => ctx.post.id,
          "field" => ctx.field.name,
          "targets" => Enum.map(targets, &%{"id" => &1.id})
        },
        context: %{actor: ctx.editor}
      )
    end

    assert {:ok, %{data: %{"addPostReferences" => %{"errors" => [], "result" => %{}}}}} =
             run.([ctx.live])

    assert {:ok, %{data: %{"addPostReferences" => %{"result" => nil, "errors" => [error]}}}} =
             run.([ctx.draft])

    assert error["message"] =~ "isn't one of the records this field accepts"
  end

  test "/api/schema describes the selection, tag and category as ids", ctx do
    n = System.unique_integer([:positive])
    tag = CMS.create_tag!(%{name: "T#{n}", slug: "t-#{n}"}, actor: ctx.admin)
    category = CMS.create_category!(%{name: "C#{n}", slug: "c-#{n}"}, actor: ctx.admin)

    CMS.update_field_definition!(
      ctx.field,
      %{
        selection: %{
          "states" => ["published"],
          "owner" => "self",
          "sort" => "title",
          "by_type" => %{"page" => %{"tags_any" => [tag.id], "category" => category.id}}
        }
      },
      actor: ctx.admin
    )

    conn = get(build_conn(), "/api/schema?type=post")
    assert conn.status == 200

    props =
      conn.resp_body
      |> Jason.decode!()
      |> get_in(["$defs", "content_post", "properties", "custom_fields", "properties"])

    assert props[ctx.field.name]["x-kiln-selection"] == %{
             "states" => ["published"],
             "owner" => "self",
             "sort" => "title",
             "by_type" => %{"page" => %{"tags_any" => [tag.id], "category" => category.id}}
           }
  end

  test "/api/schema never names a private field in a selection", ctx do
    secret =
      CMS.create_field_definition!(
        %{content_type: :page, name: "secret", label: "Secret", field_type: :string},
        actor: ctx.admin
      )

    CMS.update_field_definition!(
      ctx.field,
      %{selection: %{"by_type" => %{"page" => %{"fields" => %{"secret" => "classified"}}}}},
      actor: ctx.admin
    )

    Ash.Seed.update!(secret, %{private: true})

    body = build_conn() |> get("/api/schema?type=post") |> Map.fetch!(:resp_body)
    refute body =~ "classified"
    refute body =~ "x-kiln-selection"
  end

  test "/api/schema leaves out what a selection names that no longer exists", ctx do
    n = System.unique_integer([:positive])
    gone = CMS.create_tag!(%{name: "G#{n}", slug: "g-#{n}"}, actor: ctx.admin)

    CMS.update_field_definition!(
      ctx.field,
      %{selection: %{"by_type" => %{"page" => %{"tags_any" => [gone.id]}}}},
      actor: ctx.admin
    )

    CMS.destroy_tag!(gone, actor: ctx.admin)

    props =
      KilnCMS.SchemaExport.json_schema(types: ["post"])
      |> get_in(["$defs", "content_post", "properties", "custom_fields", "properties"])

    refute Map.has_key?(props[ctx.field.name], "x-kiln-selection")
  end
end
