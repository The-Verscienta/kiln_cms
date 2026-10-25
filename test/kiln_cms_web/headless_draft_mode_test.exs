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

      # A write never consults the token, so the draft stays as invisible to
      # it as to any anonymous caller.
      assert conn.status == 404
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
      # A supported locale that is not the record's names another document…
      assert_invalid_preview(artifact("post", mine.slug, tok, %{"locale" => "fr"}))
      # …while an unsupported one is the same 400 the published read answers,
      # not a lapsed token.
      assert %{"errors" => [%{"code" => "unsupported_locale"}]} =
               json_response(artifact("post", mine.slug, tok, %{"locale" => "zz"}), 400)

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

  describe "a live document's pending working copy" do
    defp pending(admin) do
      post = published_post(admin)

      Ash.Seed.update!(post, %{
        working_title: "Pending title",
        working_blocks: post.blocks,
        working_fields: %{"slug" => post.slug <> "-renamed"},
        working_copy_at: DateTime.utc_now()
      })

      post
    end

    test "JSON:API under the token answers the working copy; without it, the live row" do
      post = pending(user(:admin))

      attrs = fn token ->
        "/api/json/posts/#{post.id}"
        |> json_api(token)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()
        |> get_in(["data", "attributes"])
      end

      assert %{"title" => "Pending title", "slug" => renamed} = attrs.(token(post))
      assert renamed == post.slug <> "-renamed"
      assert %{"title" => "Draft title"} = attrs.(nil)

      # A sparse fieldset still sees the copy: its columns are selected anyway.
      sparse =
        "/api/json/posts/#{post.id}?fields[post]=title"
        |> json_api(token(post))
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert sparse["data"]["attributes"] == %{"title" => "Pending title"}
    end

    test "the artifact route answers at the live slug and at the held one" do
      post = pending(user(:admin))
      tok = token(post)

      for slug <- [post.slug, post.slug <> "-renamed"] do
        assert json_response(artifact("post", slug, tok), 200)["title"] == "Pending title"
      end
    end
  end

  describe "a passphrase-locked draft" do
    test "the token passes the lock on JSON:API; nothing else does" do
      post = draft_post(user(:admin))
      Ash.Seed.update!(post, %{access_password_hash: Bcrypt.hash_pwd_salt("open sesame")})

      assert json_api("/api/json/posts/#{post.id}").status == 404

      conn = json_api("/api/json/posts/#{post.id}", token(post))
      assert %{"data" => %{"id" => id}} = Jason.decode!(conn.resp_body)
      assert id == post.id
    end
  end

  describe "surfaces" do
    test "json_ld renders, and llm is raw Markdown" do
      post = draft_post(user(:admin))
      tok = token(post)

      assert %{"@context" => _} =
               json_response(artifact("post", post.slug, tok, %{"surface" => "json_ld"}), 200)

      llm = artifact("post", post.slug, tok, %{"surface" => "llm"})
      assert ["text/markdown" <> _] = get_resp_header(llm, "content-type")
      assert llm.resp_body =~ "Draft heading"
      refute llm.resp_body =~ ~s("markdown")
    end

    test "an admin-defined type previews on both routes" do
      admin = user(:admin)
      name = "hdm_type_#{System.unique_integer([:positive])}"

      definition =
        CMS.create_type_definition!(%{name: name, label: "HDM"}, actor: admin)

      entry =
        CMS.create_entry!(
          %{title: "Entry draft", slug: slug(), type_definition_id: definition.id},
          actor: admin
        )

      tok = token(entry)

      assert json_api("/api/json/entries/#{entry.id}").status == 404
      conn = json_api("/api/json/entries/#{entry.id}", tok)
      assert %{"data" => %{"id" => id}} = Jason.decode!(conn.resp_body)
      assert id == entry.id

      assert json_response(artifact(name, entry.slug, tok), 200)["title"] == "Entry draft"
    end
  end

  describe ":reference fields" do
    setup do
      admin = user(:admin)
      field = "hdm_ref_#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: field,
          label: "Ref",
          field_type: :reference,
          target_types: ["post"],
          multiple: true
        },
        actor: admin
      )

      %{admin: admin, field: field}
    end

    test "a published document's reference to the shared draft is not masked under its token",
         %{admin: admin, field: field} do
      draft = draft_post(admin, %{title: "Shared draft"})

      referrer =
        published_post(admin, %{
          custom_fields: %{field => [%{"id" => draft.id, "type" => "post"}]}
        })

      refs = fn token ->
        "/api/json/posts/#{referrer.id}"
        |> json_api(token)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()
        |> get_in(["data", "attributes", "custom_fields", field])
      end

      assert [%{"id" => id, "title" => "Shared draft"}] = refs.(token(draft))
      assert id == draft.id
      assert refs.(nil) in [nil, []]
    end

    test "?expand= follows the working copy's references, not the live row's edges",
         %{admin: admin, field: field} do
      live_target = published_post(admin, %{title: "Live target"})
      pending_target = published_post(admin, %{title: "Pending target"})

      post =
        published_post(admin, %{
          custom_fields: %{field => [%{"id" => live_target.id, "type" => "post"}]}
        })

      Ash.Seed.update!(post, %{
        working_title: post.title,
        working_blocks: post.blocks,
        working_fields: %{
          "custom_fields" => %{field => [%{"id" => pending_target.id, "type" => "post"}]}
        },
        working_copy_at: DateTime.utc_now()
      })

      KilnCMS.DataCase.drain_oban()

      body = json_response(artifact("post", post.slug, token(post), %{"expand" => field}), 200)
      assert [%{"id" => id}] = body["expanded"][field]
      assert id == pending_target.id
    end
  end

  describe "surfaces that ignore the token" do
    test "search keeps its public caching when a token is presented" do
      post = draft_post(user(:admin))

      conn =
        build_conn()
        |> with_token(token(post))
        |> get("/api/search", %{"q" => "anything"})

      refute get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end
end
