defmodule KilnCMSWeb.ConditionalWriteTest do
  @moduledoc """
  Optimistic concurrency on the headless write surface: the `ETag` a
  single-record response carries, `If-Match` on the JSON:API writes, and
  `expected_lock_version` on the GraphQL mutations
  (`KilnCMS.CMS.Changes.CheckExpectedVersion`).

  The case all of this exists for is the clobber: an API client reads a
  document, an editor saves it, and the client's PATCH — built from the copy it
  read — lands on top. Without a precondition that is a silent overwrite of the
  editor's work.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cw-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner) do
    owner.id
    |> Accounts.mint_api_key!(
      "conditional",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "cw-#{System.unique_integer([:positive])}"

  defp req(method, path, key, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn =
      case opts[:if_match] do
        nil -> conn
        tag -> put_req_header(conn, "if-match", tag)
      end

    conn =
      case opts[:attrs] do
        nil ->
          dispatch(conn, @endpoint, method, path)

        attrs ->
          ["", "api", "json", _plural, id | _] = String.split(path, "/")
          body = %{data: %{type: "page", id: id, attributes: attrs}}
          dispatch(conn, @endpoint, method, path, Jason.encode!(body))
      end

    body = if conn.resp_body in [nil, ""], do: %{}, else: Jason.decode!(conn.resp_body)
    {conn.status, get_resp_header(conn, "etag"), body}
  end

  setup do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Original", slug: slug()}, actor: admin)
    %{admin: admin, key: key(admin), page: page}
  end

  describe "the ETag" do
    test "a single-record read carries one built from lock_version and state", ctx do
      assert {200, [~s("1-draft")], body} = req(:get, "/api/json/pages/#{ctx.page.id}", ctx.key)
      assert body["data"]["attributes"]["lock_version"] == 1
    end

    test "a write answers with the new one", ctx do
      assert {200, [~s("2-draft")], body} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                 attrs: %{title: "Edited"},
                 if_match: ~s("1-draft")
               )

      assert body["data"]["attributes"]["lock_version"] == 2

      # A workflow transition moves `state`, not `lock_version`, and the tag
      # moves with it.
      assert {200, [~s("2-published")], _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}/publish", ctx.key, attrs: %{})
    end

    test "lock_version cannot be written", ctx do
      req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key, attrs: %{lock_version: 99})

      refute CMS.get_page!(ctx.page.id, actor: ctx.admin).lock_version == 99
    end
  end

  describe "If-Match on PATCH" do
    test "an editor's save since the read refuses the PATCH with 412, and survives", ctx do
      {200, [etag], _} = req(:get, "/api/json/pages/#{ctx.page.id}", ctx.key)

      # The editor saves while the API client is still holding its copy.
      CMS.update_page!(ctx.page, %{title: "Editor's words"}, actor: ctx.admin)

      assert {412, [], body} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                 attrs: %{title: "Client's stale copy"},
                 if_match: etag
               )

      assert [error] = body["errors"]
      assert error["code"] == "precondition_failed"
      assert error["meta"]["etag"] == ~s("2-draft")
      assert error["meta"]["lock_version"] == 2

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Editor's words"
    end

    test "without If-Match nothing changes: the write applies (last write wins)", ctx do
      CMS.update_page!(ctx.page, %{title: "Editor's words"}, actor: ctx.admin)

      assert {200, _, _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key, attrs: %{title: "Blind"})

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Blind"
    end

    test "a publish since the read refuses a PATCH written against the draft", ctx do
      {200, [etag], _} = req(:get, "/api/json/pages/#{ctx.page.id}", ctx.key)
      CMS.publish_page!(ctx.page, %{}, actor: ctx.admin)

      assert {412, _, _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                 attrs: %{title: "Meant for a draft"},
                 if_match: etag
               )

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Original"
    end

    test "* matches whatever is there; any one of several tags is enough", ctx do
      assert {200, _, _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                 attrs: %{title: "Star"},
                 if_match: "*"
               )

      assert {200, [~s("3-draft")], _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                 attrs: %{title: "List"},
                 if_match: ~s("1-draft", "2-draft")
               )
    end

    # A tag the server could never have issued must fail the precondition.
    # Ignoring it would turn a typo into an unguarded write.
    test "a weak, foreign or garbled tag fails rather than being ignored", ctx do
      for tag <- [~s(W/"1-draft"), ~s("abc"), "1-draft", ~s("1-published")] do
        assert {412, _, _} =
                 req(:patch, "/api/json/pages/#{ctx.page.id}", ctx.key,
                   attrs: %{title: "Nope"},
                   if_match: tag
                 ),
               tag
      end

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Original"
    end
  end

  describe "If-Match on the workflow verbs and DELETE" do
    test "publish refuses a version it was not shown", ctx do
      {200, [etag], _} = req(:get, "/api/json/pages/#{ctx.page.id}", ctx.key)
      CMS.update_page!(ctx.page, %{title: "Unreviewed edit"}, actor: ctx.admin)

      assert {412, _, _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}/publish", ctx.key,
                 attrs: %{},
                 if_match: etag
               )

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).state == :draft

      assert {200, [~s("2-published")], _} =
               req(:patch, "/api/json/pages/#{ctx.page.id}/publish", ctx.key,
                 attrs: %{},
                 if_match: ~s("2-draft")
               )
    end

    test "DELETE with a stale tag leaves the document where it is", ctx do
      CMS.update_page!(ctx.page, %{title: "Still wanted"}, actor: ctx.admin)

      assert {412, _, _} =
               req(:delete, "/api/json/pages/#{ctx.page.id}", ctx.key, if_match: ~s("1-draft"))

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin)

      assert {status, _, _} =
               req(:delete, "/api/json/pages/#{ctx.page.id}", ctx.key, if_match: ~s("2-draft"))

      assert status in [200, 204]
      assert [] = CMS.list_pages!(actor: ctx.admin, query: [filter: [id: ctx.page.id]])
    end
  end

  describe "expected_lock_version over GraphQL" do
    defp gql(query, variables, key) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{key}")
      |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    @update """
    mutation ($id: ID!, $input: UpdatePageInput!) {
      updatePage(id: $id, input: $input) {
        result { title lockVersion }
        errors { code message vars }
      }
    }
    """

    test "a stale version is refused with precondition_failed and the current one", ctx do
      CMS.update_page!(ctx.page, %{title: "Editor's words"}, actor: ctx.admin)

      body =
        gql(
          @update,
          %{id: ctx.page.id, input: %{title: "Stale", expectedLockVersion: 1}},
          ctx.key
        )

      assert body["data"]["updatePage"]["result"] == nil
      assert [error] = body["data"]["updatePage"]["errors"]
      assert error["code"] == "precondition_failed"
      assert error["vars"]["lock_version"] == 2
      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Editor's words"
    end

    test "the current version applies, and lockVersion reads back", ctx do
      body =
        gql(
          @update,
          %{id: ctx.page.id, input: %{title: "Fresh", expectedLockVersion: 1}},
          ctx.key
        )

      assert body["data"]["updatePage"]["result"] == %{"title" => "Fresh", "lockVersion" => 2}
    end

    test "the workflow mutations take it too", ctx do
      query = """
      mutation ($id: ID!, $input: PublishPageInput) {
        publishPage(id: $id, input: $input) { result { state } errors { code } }
      }
      """

      body = gql(query, %{id: ctx.page.id, input: %{expectedLockVersion: 7}}, ctx.key)
      assert [%{"code" => "precondition_failed"}] = body["data"]["publishPage"]["errors"]

      body = gql(query, %{id: ctx.page.id, input: %{expectedLockVersion: 1}}, ctx.key)
      assert body["data"]["publishPage"]["result"] == %{"state" => "published"}
    end
  end
end
