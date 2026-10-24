defmodule KilnCMSWeb.HeadlessDraftModeTest do
  @moduledoc """
  Headless draft mode (#1887): a preview token, presented on the plain reads a
  front end already uses — JSON:API by id with `include=`, and the fired-artifact
  route — reads the one draft it names, and nothing else.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.PreviewToken

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "hdm-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "hdm-#{System.unique_integer([:positive])}"

  defp draft_post(admin, attrs \\ %{}) do
    CMS.create_post!(
      Map.merge(
        %{
          title: "Draft title",
          slug: slug(),
          block_tree:
            KilnCMS.TypedFixtures.typed_blocks([
              %{"type" => "heading", "content" => "Draft heading", "order" => 1}
            ])
        },
        attrs
      ),
      actor: admin
    )
  end

  defp published_post(admin, attrs \\ %{}),
    do: admin |> draft_post(attrs) |> then(&CMS.publish_post!(&1, %{}, actor: admin))

  defp token(record), do: PreviewToken.sign(record)

  defp expired_token(record) do
    Phoenix.Token.sign(
      KilnCMSWeb.Endpoint,
      "content preview",
      %{type: ContentTypes.type_name_for(record), id: record.id, org_id: record.org_id},
      signed_at: System.system_time(:second) - PreviewToken.max_age_seconds() - 1
    )
  end

  defp with_token(conn, nil), do: conn
  defp with_token(conn, token), do: put_req_header(conn, "x-kiln-preview-token", token)

  defp json_api(path, token \\ nil) do
    build_conn()
    |> put_req_header("accept", @accept)
    |> with_token(token)
    |> get(path)
  end

  defp artifact(type, slug, token, params \\ %{}) do
    build_conn() |> with_token(token) |> get("/api/content/#{type}/#{slug}", params)
  end

  defp assert_invalid_preview(conn) do
    assert %{"errors" => [%{"code" => "invalid_preview"}]} = Jason.decode!(conn.resp_body)
    assert conn.status == 404
  end

  describe "JSON:API" do
    test "a token reads the draft it names by id; without one the draft is a 404" do
      post = draft_post(user(:admin))

      assert json_api("/api/json/posts/#{post.id}").status == 404

      conn = json_api("/api/json/posts/#{post.id}", token(post))
      assert %{"data" => %{"id" => id, "attributes" => attrs}} = Jason.decode!(conn.resp_body)
      assert id == post.id
      assert attrs["title"] == "Draft title"

      # The body is the token's, not the URL's.
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "x-kiln-preview-token"
    end

    test "the token also rides the query string" do
      post = draft_post(user(:admin))

      conn = json_api("/api/json/posts/#{post.id}?preview_token=#{token(post)}")
      assert %{"data" => %{"id" => id}} = Jason.decode!(conn.resp_body)
      assert id == post.id
    end

    test "a token names one record: another draft stays hidden, in a list too" do
      admin = user(:admin)
      mine = draft_post(admin)
      theirs = draft_post(admin)

      assert json_api("/api/json/posts/#{theirs.id}", token(mine)).status == 404

      conn =
        json_api(
          "/api/json/posts?filter[id][in][]=#{mine.id}&filter[id][in][]=#{theirs.id}",
          token(mine)
        )

      assert %{"data" => [%{"id" => id}]} = Jason.decode!(conn.resp_body)
      assert id == mine.id
    end

    test "only the primary read: the published-only by-slug route ignores the grant" do
      post = draft_post(user(:admin))

      conn =
        json_api("/api/json/posts/by-slug/#{post.slug}?locale=#{post.locale}", token(post))

      assert conn.status == 404
    end

    test "the draft's edges to published documents are included; edges to other drafts are not" do
      admin = user(:admin)
      draft = draft_post(admin)
      live = published_post(admin)
      other_draft = draft_post(admin)
      incoming = published_post(admin)

      for {source, target} <- [{draft, live}, {draft, other_draft}, {incoming, draft}] do
        CMS.create_content_link!(%{source_id: source.id, target_id: target.id, kind: :see_also},
          actor: admin
        )
      end

      body =
        "/api/json/posts/#{draft.id}?include=content_links,incoming_links"
        |> json_api(token(draft))
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      links = for %{"type" => "content_link", "attributes" => a} <- body["included"], do: a

      assert links |> Enum.map(&{&1["source_id"], &1["target_id"]}) |> Enum.sort() ==
               Enum.sort([{draft.id, live.id}, {incoming.id, draft.id}])

      # And the published document does not list the draft's edge to it to an
      # anonymous reader.
      anon =
        "/api/json/posts/#{incoming.id}?include=content_links"
        |> json_api()
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert anon["data"]["relationships"]["content_links"]["data"] == []
    end

    test "an invalid, expired or other-site token is a 404 invalid_preview, never the anonymous read" do
      admin = user(:admin)
      live = published_post(admin)

      assert json_api("/api/json/posts/#{live.id}").status == 200
      assert_invalid_preview(json_api("/api/json/posts/#{live.id}", "garbage"))
      assert_invalid_preview(json_api("/api/json/posts/#{live.id}", expired_token(live)))

      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org HDM",
          slug: "hdm-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      elsewhere = CMS.create_post!(%{title: "Elsewhere", slug: slug()}, actor: admin, tenant: org)

      assert_invalid_preview(json_api("/api/json/posts/#{elsewhere.id}", token(elsewhere)))
    end

    test "writes are not widened" do
      post = draft_post(user(:admin))

      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> put_req_header("content-type", @accept)
        |> with_token(token(post))
        |> patch("/api/json/posts/#{post.id}", %{
          data: %{type: "post", id: post.id, attributes: %{title: "Hijacked"}}
        })

      assert conn.status in [403, 404]
      assert CMS.get_post!(post.id, authorize?: false, tenant: post.org_id).title == "Draft title"
    end
  end

  describe "fired-artifact route" do
    test "a token renders the draft live, in the published artifact's shape, uncached" do
      post = draft_post(user(:admin))

      assert artifact("post", post.slug, nil).status == 404

      conn = artifact("post", post.slug, token(post))
      body = json_response(conn, 200)
      assert body["id"] == post.id
      assert body["title"] == "Draft title"
      assert [%{"text" => "Draft heading"}] = body["blocks"]

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "x-kiln-locale") == [post.locale]
    end

    test "every surface renders, and ?fields= applies" do
      post = draft_post(user(:admin))
      tok = token(post)

      assert %{"html" => html} =
               json_response(artifact("post", post.slug, tok, %{"surface" => "web"}), 200)

      assert html =~ "Draft heading"

      llm = artifact("post", post.slug, tok, %{"surface" => "llm"})
      assert llm.status == 200
      assert llm.resp_body =~ "Draft heading"

      assert body = json_response(artifact("post", post.slug, tok, %{"fields" => "title"}), 200)
      assert Map.keys(body) |> Enum.sort() == ["id", "title", "type"]
    end

    test "a live document with pending edits renders its working copy" do
      admin = user(:admin)
      post = published_post(admin)

      Ash.Seed.update!(post, %{
        working_title: "Pending title",
        working_blocks: post.blocks,
        working_copy_at: DateTime.utc_now()
      })

      assert json_response(artifact("post", post.slug, token(post)), 200)["title"] ==
               "Pending title"
    end

    test "the URL must name the token's record" do
      admin = user(:admin)
      mine = draft_post(admin)
      theirs = draft_post(admin)
      tok = token(mine)

      assert_invalid_preview(artifact("post", theirs.slug, tok))
      assert_invalid_preview(artifact("page", mine.slug, tok))
      assert_invalid_preview(artifact("post", mine.slug, tok, %{"locale" => "zz"}))
      assert_invalid_preview(artifact("post", mine.slug, expired_token(mine)))
    end

    test "the published artifact says it varies on the token" do
      admin = user(:admin)
      live = published_post(admin)
      KilnCMS.Firing.Engine.fire(live)

      conn = artifact("post", live.slug, nil)
      assert conn.status == 200
      assert [vary] = get_resp_header(conn, "vary")
      assert vary =~ "x-kiln-preview-token"
    end
  end
end
