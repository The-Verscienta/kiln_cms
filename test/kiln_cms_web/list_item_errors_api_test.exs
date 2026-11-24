defmodule KilnCMSWeb.ListItemErrorsApiTest do
  @moduledoc """
  A value rule's refusal of one item of a scalar list through the headless
  surfaces (#2683): the text names the item by its position from 1, as a
  coercion error does, while the machine-read parts of the error — the
  JSON:API `code` and `source.pointer`, the GraphQL `code` and `fields` — stay
  what they were, naming the `custom_fields` attribute and no item.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @schema KilnCMSWeb.GraphqlSchema

  @update """
  mutation ($id: ID!, $input: UpdatePageInput!) {
    updatePage(id: $id, input: $input) {
      result { id }
      errors { message code fields }
    }
  }
  """

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lie-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp key(actor) do
    actor.id
    |> Accounts.mint_api_key!(
      "list-item-errors",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: actor
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp api_patch(page, key, custom_fields) do
    body = %{data: %{type: "page", id: page.id, attributes: %{custom_fields: custom_fields}}}

    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> patch("/api/json/pages/#{page.id}", Jason.encode!(body))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  setup do
    admin = admin()

    field =
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "lie_scores_#{System.unique_integer([:positive])}",
          label: "Scores",
          field_type: :integer,
          multiple: true,
          validation: %{"max" => 10}
        },
        actor: admin
      )

    page =
      CMS.create_page!(%{title: "Scores", slug: "lie-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    %{admin: admin, field: field, page: page}
  end

  test "JSON:API names the item from 1 under the same code and pointer", ctx do
    assert {400, body} = api_patch(ctx.page, key(ctx.admin), %{ctx.field.name => [3, 11]})

    assert [
             %{
               "code" => "invalid_attribute",
               "detail" => detail,
               "source" => %{"pointer" => "/data/attributes/custom_fields"}
             } = error
           ] = body["errors"]

    assert detail == "Scores (#{ctx.field.name}) item 2 must be at most 10"
    assert Map.get(error, "meta", %{}) == %{}
    assert CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields == %{}
  end

  test "GraphQL names the item from 1 under the same code and fields", ctx do
    assert {:ok, %{data: %{"updatePage" => %{"result" => nil, "errors" => [error]}}}} =
             Absinthe.run(@update, @schema,
               variables: %{
                 "id" => ctx.page.id,
                 "input" => %{"customFields" => Jason.encode!(%{ctx.field.name => [3, 11]})}
               },
               context: %{actor: ctx.admin}
             )

    assert error == %{
             "message" => "Scores (#{ctx.field.name}) item 2 must be at most 10",
             "code" => "invalid_attribute",
             "fields" => ["custom_fields"]
           }
  end
end
