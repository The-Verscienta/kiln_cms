defmodule KilnCMSWeb.VisualEditingControllerTest do
  @moduledoc """
  `GET /api/visual-editing/:type/:slug` (#355) — the stega-annotated live preview
  the bridge overlay reads. Draft visibility follows the caller's actor.
  """
  # async: false — one test toggles the global `:visual_editing_enabled` config.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.VisualEditing.Stega

  @password "password123456"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ve-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp key(owner, access) do
    k =
      Accounts.mint_api_key!(
        owner.id,
        "ve",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(k, :plaintext_api_key)
  end

  defp slug, do: "ve-#{System.unique_integer([:positive])}"

  defp draft_post(admin) do
    CMS.create_post!(
      %{
        title: "Live title",
        slug: slug(),
        block_tree: [%{"type" => "heading", "content" => "A heading", "order" => 1}]
      },
      actor: admin
    )
  end

  defp get_ve(conn, type, slug, opts \\ []) do
    conn =
      case opts[:bearer] do
        nil -> conn
        tok -> put_req_header(conn, "authorization", "Bearer #{tok}")
      end

    get(conn, "/api/visual-editing/#{type}/#{slug}")
  end

  test "an editor API key sees the draft, stega-annotated with the doc address", %{conn: conn} do
    admin = user(:admin)
    post = draft_post(admin)

    conn = get_ve(conn, "post", post.slug, bearer: key(admin, :read))

    assert %{"id" => id, "type" => "post", "title" => title, "blocks" => blocks} =
             json_response(conn, 200)

    assert id == post.id
    # Title carries the document address and cleans back to the visible text.
    assert Stega.decode(title) ==
             %{"type" => "post", "id" => post.id, "slug" => post.slug, "field" => "title"}

    assert Stega.clean(title) == "Live title"

    # Blocks carry their stable _id (the bridge's addressing anchor).
    assert [%{"_id" => block_id, "_type" => "heading", "text" => text}] = blocks
    assert is_binary(block_id)

    assert Stega.decode(text) ==
             %{
               "type" => "post",
               "id" => post.id,
               "slug" => post.slug,
               "field" => "text",
               "block" => block_id
             }

    # Per-actor draft content must not be shared-cached.
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "custom fields ride the annotated preview, stega-encoded field-level", %{conn: conn} do
    admin = user(:admin)

    CMS.create_field_definition!(
      %{content_type: :post, name: "byline", label: "Byline", field_type: :string},
      actor: admin
    )

    post =
      CMS.create_post!(
        %{title: "CF post", slug: slug(), custom_fields: %{"byline" => "By A. Author"}},
        actor: admin
      )

    conn = get_ve(conn, "post", post.slug, bearer: key(admin, :read))

    assert %{"custom_fields" => %{"byline" => byline}} = json_response(conn, 200)

    # The value cleans back to the visible text and decodes to a block-less
    # address — the bridge routes it to /editor/content/:type/:id?focus=byline.
    assert Stega.clean(byline) == "By A. Author"

    assert Stega.decode(byline) ==
             %{"type" => "post", "id" => post.id, "slug" => post.slug, "field" => "byline"}
  end

  test "an anonymous caller cannot see a draft (404), only published", %{conn: conn} do
    admin = user(:admin)
    post = draft_post(admin)

    # Anonymous → draft invisible.
    assert conn |> get_ve("post", post.slug) |> json_response(404)

    # Publish, then anonymous can read it (annotated).
    CMS.publish_post!(post, %{}, actor: admin)
    body = build_conn() |> get_ve("post", post.slug) |> json_response(200)
    assert body["id"] == post.id
    assert Stega.clean(body["title"]) == "Live title"
  end

  test "unknown type/slug is a 404", %{conn: conn} do
    assert conn
           |> get_ve("post", "nope-#{System.unique_integer([:positive])}")
           |> json_response(404)

    assert conn |> get_ve("bogustype", "x") |> json_response(404)
  end

  test "the bridge.js SDK is served as a static asset", %{conn: conn} do
    conn = get(conn, "/bridge.js")
    assert conn.status == 200
    assert conn.resp_body =~ "KilnBridge"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "javascript"
  end

  test "returns 404 when visual editing is disabled", %{conn: conn} do
    admin = user(:admin)
    post = draft_post(admin)

    Application.put_env(:kiln_cms, :visual_editing_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :visual_editing_enabled) end)

    assert conn |> get_ve("post", post.slug, bearer: key(admin, :read)) |> json_response(404)
  end

  describe "tenant scoping (#336)" do
    test "the read is scoped to the request host's org", %{conn: conn} do
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org VE",
          slug: "ve-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      admin = user(:admin)
      the_slug = slug()

      CMS.create_post!(
        %{
          title: "Other-site post",
          slug: the_slug,
          block_tree: [%{"type" => "heading", "content" => "A heading", "order" => 1}]
        },
        actor: admin,
        tenant: org
      )

      bearer = key(admin, :read)

      # On the default host the document belongs to another org — invisible,
      # even to an editor key that could read it on its own site.
      assert conn |> get_ve("post", the_slug, bearer: bearer) |> json_response(404)

      # On the owning org's subdomain the same request resolves it.
      org_host_conn = %{build_conn() | host: "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"}

      assert %{"title" => title} =
               org_host_conn |> get_ve("post", the_slug, bearer: bearer) |> json_response(200)

      assert Stega.clean(title) == "Other-site post"
    end
  end
end
