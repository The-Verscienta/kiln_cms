defmodule KilnCMSWeb.WorkingCopyApiTest do
  @moduledoc """
  The headless API and the working copy of a live document (#1815,
  docs/working-copy.md).

  Reads serve the published content only: a held SEO title or custom field is
  never on the JSON:API, whoever asks. Writes keep their documented
  semantics: a `PATCH` to a published record is a live edit through `:update`,
  as it was before the working copy covered every field — an integration that
  writes through the API has no "Publish changes" step to wait for.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.WorkingCopy

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wc-api-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "working-copy",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp req(method, path, key, attrs \\ nil) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn =
      case attrs do
        nil ->
          dispatch(conn, @endpoint, method, path)

        attrs ->
          ["", "api", "json", _plural, id | _] = String.split(path, "/")
          body = %{data: %{type: "page", id: id, attributes: attrs}}
          dispatch(conn, @endpoint, method, path, Jason.encode!(body))
      end

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  setup do
    admin = user(:admin)

    page =
      CMS.create_page!(
        %{
          title: "Live",
          slug: "wc-api-#{System.unique_integer([:positive])}",
          seo_title: "Live SEO"
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    %{admin: admin, key: key(admin), page: page}
  end

  test "a read serves the published values, never the held ones", ctx do
    {:ok, _} =
      CMS.save_page_working_copy(ctx.page, %{fields: %{"seo_title" => "Held SEO"}},
        actor: ctx.admin,
        tenant: ctx.page.org_id
      )

    assert {200, body} = req(:get, "/api/json/pages/#{ctx.page.id}", ctx.key)
    attributes = body["data"]["attributes"]
    assert attributes["seo_title"] == "Live SEO"
    refute Map.has_key?(attributes, "working_fields")
  end

  # The lost-update guard (#1815): the PATCH stays a live edit, and a later
  # "Publish changes" may not overwrite it without someone deciding to.
  test "a PATCH to a field the draft holds is not overwritten by Publish changes", ctx do
    {:ok, _} =
      CMS.save_page_working_copy(ctx.page, %{fields: %{"seo_title" => "Held SEO"}},
        actor: ctx.admin,
        tenant: ctx.page.org_id
      )

    assert {200, _body} =
             req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key, %{seo_title: "From the API"})

    page = CMS.get_page!(ctx.page.id, authorize?: false, tenant: ctx.page.org_id)
    assert WorkingCopy.pending?(page)
    assert {:error, _} = CMS.publish_page_changes(page, actor: ctx.admin)

    page = CMS.get_page!(ctx.page.id, authorize?: false, tenant: ctx.page.org_id)
    assert page.seo_title == "From the API"
  end

  test "a PATCH to a published record is still a live edit", ctx do
    assert {200, _body} =
             req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key, %{seo_title: "From the API"})

    page = CMS.get_page!(ctx.page.id, authorize?: false, tenant: ctx.page.org_id)
    assert page.seo_title == "From the API"
    refute WorkingCopy.pending?(page)
  end
end
