defmodule KilnCMSWeb.ArtifactExpandTest do
  @moduledoc """
  Workstream R7 of `docs/relationships-plan.md`, JSON side:
  `GET /api/content/:type/:slug?expand=<field>` adds the targets of a
  document's `:reference` fields, each with its own `json` artifact.

  Delivery is actorless, so a target is expanded only when an anonymous
  reader could read it: never a draft. The source end is the delivery read
  itself, which never serves a draft.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "exp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "exp-#{System.unique_integer([:positive])}"
  defp ref(record, type), do: %{"id" => record.id, "type" => type}

  setup do
    admin = admin()
    field = "linked_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: field,
        label: "Linked",
        field_type: :reference,
        target_types: ["page", "post"],
        multiple: true
      },
      actor: admin
    )

    live_page =
      CMS.create_page!(%{title: "Live page", slug: slug()}, actor: admin)
      |> CMS.publish_page!(actor: admin)

    draft_page = CMS.create_page!(%{title: "Draft page", slug: slug()}, actor: admin)

    live_post =
      CMS.create_post!(%{title: "Live post", slug: slug()}, actor: admin)
      |> CMS.publish_post!(actor: admin)

    source =
      CMS.create_post!(
        %{
          title: "Source",
          slug: slug(),
          custom_fields: %{
            field => [ref(live_page, "page"), ref(draft_page, "page"), ref(live_post, "post")]
          }
        },
        actor: admin
      )
      |> CMS.publish_post!(actor: admin)

    # Firing is async (#201): store every artifact before the requests.
    KilnCMS.DataCase.drain_oban()

    %{
      admin: admin,
      field: field,
      source: source,
      live_page: live_page,
      draft_page: draft_page,
      live_post: live_post
    }
  end

  defp expand(conn, source, expand, extra \\ "") do
    get(conn, "/api/content/post/#{source.slug}?expand=#{expand}#{extra}")
  end

  test "expands published targets with their artifacts, in the field's order", ctx do
    body = ctx.conn |> expand(ctx.source, ctx.field) |> json_response(200)

    # The artifact itself is unchanged; `expanded` is added beside it.
    assert body["title"] == "Source"

    assert [page, post] = body["expanded"][ctx.field]

    assert %{"position" => 0, "link" => %{}, "type" => "page", "id" => page_id} = page
    assert page_id == ctx.live_page.id
    assert page["slug"] == ctx.live_page.slug
    assert page["target"]["title"] == "Live page"
    assert page["target"]["type"] == "page"

    assert %{"position" => 2, "type" => "post"} = post
    assert post["target"]["title"] == "Live post"
  end

  test "a draft target is never expanded", ctx do
    body = ctx.conn |> expand(ctx.source, ctx.field) |> json_response(200)
    ids = Enum.map(body["expanded"][ctx.field], & &1["id"])

    refute ctx.draft_page.id in ids
    refute inspect(body["expanded"]) =~ "Draft page"
  end

  test "a draft source is not served, expanded or not", ctx do
    draft =
      CMS.create_post!(
        %{
          title: "Draft source",
          slug: slug(),
          custom_fields: %{ctx.field => [ref(ctx.live_page, "page")]}
        },
        actor: ctx.admin
      )

    assert ctx.conn |> expand(draft, ctx.field) |> json_response(404)
  end

  test "every requested field is a key; one with no targets is an empty list", ctx do
    body = ctx.conn |> expand(ctx.source, "#{ctx.field},nothing_here") |> json_response(200)

    assert Map.keys(body["expanded"]) |> Enum.sort() == Enum.sort([ctx.field, "nothing_here"])
    assert body["expanded"]["nothing_here"] == []
  end

  test "without expand the response has no expanded key", ctx do
    body = ctx.conn |> get("/api/content/post/#{ctx.source.slug}") |> json_response(200)
    refute Map.has_key?(body, "expanded")
  end

  test "the ETag changes when an expanded target is republished", ctx do
    first = expand(ctx.conn, ctx.source, ctx.field)
    assert [etag] = get_resp_header(first, "etag")
    assert ["public, max-age=300"] = get_resp_header(first, "cache-control")

    # The plain response's ETag is not the expanded one.
    plain = get(build_conn(), "/api/content/post/#{ctx.source.slug}")
    refute get_resp_header(plain, "etag") == [etag]

    # Same request, nothing changed: revalidates.
    assert build_conn()
           |> put_req_header("if-none-match", etag)
           |> expand(ctx.source, ctx.field)
           |> response(304)

    # The target changes and the source does not: no longer a match.
    CMS.update_page!(ctx.live_page, %{title: "Renamed page"}, actor: ctx.admin)
    KilnCMS.DataCase.drain_oban()

    renamed =
      build_conn() |> put_req_header("if-none-match", etag) |> expand(ctx.source, ctx.field)

    body = json_response(renamed, 200)
    refute get_resp_header(renamed, "etag") == [etag]
    assert hd(body["expanded"][ctx.field])["target"]["title"] == "Renamed page"
  end

  describe "refused" do
    test "on a surface other than json", ctx do
      body =
        ctx.conn |> expand(ctx.source, ctx.field, "&surface=web") |> json_response(400)

      assert [%{"code" => "invalid_expand"}] = body["errors"]
    end

    test "with more than ten fields", ctx do
      fields = Enum.map_join(1..11, ",", &"f#{&1}")
      assert ctx.conn |> expand(ctx.source, fields) |> json_response(400)
    end

    test "as a list rather than a string", ctx do
      assert ctx.conn
             |> get("/api/content/post/#{ctx.source.slug}?expand[]=#{ctx.field}")
             |> json_response(400)
    end

    test "with as_of", ctx do
      assert ctx.conn
             |> expand(ctx.source, ctx.field, "&as_of=2030-01-01")
             |> json_response(400)
    end
  end
end
