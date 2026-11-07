defmodule KilnCMSWeb.ChangeSeveritySurfacesTest do
  @moduledoc """
  The optional `change_severity` input over the public write surfaces: JSON:API
  (`PATCH` update and the `publish` transition), GraphQL mutations and MCP
  `update_*` tools. Omitting it records `:notable` for a safety edit; an
  unknown value is a clean client error. The viewer-key read-back lives in
  `LatestEditReadBackTest`.
  """
  # async: false — the safety-field list is cached under the organization
  # alone (see CMS.ChangeSeverityTest).
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sev-surface-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner, admin, access) do
    owner.id
    |> Accounts.mint_api_key!(
      "sev-surface",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: access},
      actor: admin
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "sev-#{System.unique_integer([:positive])}"

  defp live_page(admin) do
    page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
    CMS.publish_page!(page, %{}, actor: admin)
  end

  # The newest version row carrying a severity, or nil. A live page is first
  # published with its (listed) title, so this starts at :notable, not nil.
  defp severity_of_latest(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id and &1.change_severity != nil))
    |> Enum.max_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id}, fn -> nil end)
    |> case do
      nil -> nil
      version -> version.change_severity
    end
  end

  # A refused write leaves the title as `live_page/1` set it.
  defp unchanged?(page),
    do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id).title == "Live"

  defp patch_json(path, attrs, key) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")
      |> patch(path, Jason.encode!(%{data: %{type: "page", attributes: attrs}}))

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp gql(query, variables, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp mcp(key, name, arguments) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: name, arguments: arguments}
        })
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  setup do
    admin = user(:admin)

    CMS.save_site_safety_fields!(%{fields: %{"page" => ["title"]}},
      actor: admin,
      tenant: Accounts.default_org_id()
    )

    %{admin: admin, key: key(admin, admin, :read_write)}
  end

  describe "JSON:API" do
    test "PATCH with change_severity stores it; without, :notable", ctx do
      page = live_page(ctx.admin)
      path = "/api/json/pages/#{page.id}"

      assert {200, _} =
               patch_json(path, %{title: "One", change_severity: "critical"}, ctx.key)

      assert severity_of_latest(page) == :critical

      assert {200, _} = patch_json(path, %{title: "Two"}, ctx.key)
      assert severity_of_latest(page) == :notable
    end

    test "the publish transition route accepts it too", ctx do
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: ctx.admin)
      page = CMS.submit_page_for_review!(page, %{}, actor: ctx.admin)

      assert {200, _} =
               patch_json(
                 "/api/json/pages/#{page.id}/publish",
                 %{change_severity: "routine"},
                 ctx.key
               )

      assert severity_of_latest(page) == :routine
    end

    test "an unknown value is a 4xx, not a 500", ctx do
      page = live_page(ctx.admin)
      baseline = severity_of_latest(page)

      assert {status, body} =
               patch_json(
                 "/api/json/pages/#{page.id}",
                 %{title: "Bad", change_severity: "urgent"},
                 ctx.key
               )

      assert status in 400..499
      assert is_list(body["errors"])
      assert severity_of_latest(page) == baseline
      assert unchanged?(page)
    end
  end

  describe "GraphQL" do
    @update """
    mutation ($id: ID!, $input: UpdatePageInput!) {
      updatePage(id: $id, input: $input) { result { id } errors { message } }
    }
    """

    test "updatePage takes changeSeverity; omitted records :notable", ctx do
      page = live_page(ctx.admin)

      body =
        gql(@update, %{id: page.id, input: %{title: "One", changeSeverity: "critical"}}, ctx.key)

      assert body["errors"] == nil, inspect(body["errors"])
      assert body["data"]["updatePage"]["errors"] == []
      assert severity_of_latest(page) == :critical

      body = gql(@update, %{id: page.id, input: %{title: "Two"}}, ctx.key)
      assert body["data"]["updatePage"]["errors"] == []
      assert severity_of_latest(page) == :notable
    end

    test "an unknown value is rejected, nothing is written", ctx do
      page = live_page(ctx.admin)
      baseline = severity_of_latest(page)

      body =
        gql(@update, %{id: page.id, input: %{title: "Bad", changeSeverity: "urgent"}}, ctx.key)

      assert body["errors"] != nil or body["data"]["updatePage"]["errors"] != []
      assert severity_of_latest(page) == baseline
      assert unchanged?(page)
    end
  end

  describe "MCP" do
    test "update_page takes change_severity; omitted records :notable", ctx do
      page = live_page(ctx.admin)

      assert {200, %{"result" => %{"isError" => false}}} =
               mcp(ctx.key, "update_page", %{
                 id: page.id,
                 input: %{title: "One", change_severity: "critical"}
               })

      assert severity_of_latest(page) == :critical

      assert {200, %{"result" => %{"isError" => false}}} =
               mcp(ctx.key, "update_page", %{id: page.id, input: %{title: "Two"}})

      assert severity_of_latest(page) == :notable
    end

    test "an unknown value is a tool error, nothing is written", ctx do
      page = live_page(ctx.admin)
      baseline = severity_of_latest(page)

      assert {status, body} =
               mcp(ctx.key, "update_page", %{
                 id: page.id,
                 input: %{title: "Bad", change_severity: "urgent"}
               })

      assert status < 500
      assert get_in(body, ["result", "isError"]) == true or is_map(body["error"])
      assert severity_of_latest(page) == baseline
      assert unchanged?(page)
    end
  end
end
