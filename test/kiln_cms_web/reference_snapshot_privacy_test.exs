defmodule KilnCMSWeb.ReferenceSnapshotPrivacyTest do
  @moduledoc """
  A `:reference` custom field stores a snapshot of each target
  (`%{"id", "type", "slug", "title"}`), taken when the referrer was saved.
  Serving that snapshot verbatim told an anonymous reader a draft's id, slug
  and title. Every read surface now leaves out a snapshot whose target the
  reader could not read directly: the fired artifact
  (`GET /api/content/:type/:slug`) and `custom_fields` on JSON:API and
  GraphQL. The stored value is untouched, and an editor still reads it whole.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "refpriv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "refpriv-#{System.unique_integer([:positive])}"
  defp ref(record, type), do: %{"id" => record.id, "type" => type}

  setup do
    admin = admin()
    field = "linked_#{System.unique_integer([:positive])}"
    single = "hero_#{System.unique_integer([:positive])}"

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

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: single,
        label: "Hero",
        field_type: :reference,
        target_type: "page"
      },
      actor: admin
    )

    live_page =
      CMS.create_page!(%{title: "Live page", slug: slug()}, actor: admin)
      |> CMS.publish_page!(actor: admin)

    draft_page = CMS.create_page!(%{title: "Secret draft", slug: slug()}, actor: admin)

    source =
      CMS.create_post!(
        %{
          title: "Source",
          slug: slug(),
          custom_fields: %{
            field => [ref(live_page, "page"), ref(draft_page, "page")],
            single => draft_page.id
          }
        },
        actor: admin
      )
      |> CMS.publish_post!(actor: admin)

    KilnCMS.DataCase.drain_oban()

    %{
      admin: admin,
      field: field,
      single: single,
      source: source,
      live_page: live_page,
      draft_page: draft_page
    }
  end

  defp leaks?(value, draft), do: inspect(value) =~ draft.id or inspect(value) =~ "Secret draft"

  describe "the fired json artifact" do
    test "leaves out a draft target and keeps the published one", ctx do
      body = ctx.conn |> get("/api/content/post/#{ctx.source.slug}") |> json_response(200)

      assert [%{"id" => id, "slug" => slug, "title" => "Live page"}] =
               body["custom_fields"][ctx.field]

      assert id == ctx.live_page.id
      assert slug == ctx.live_page.slug

      # A single-valued field whose only target is unreadable reads as unset.
      assert Map.has_key?(body["custom_fields"], ctx.single)
      assert body["custom_fields"][ctx.single] == nil

      refute leaks?(body, ctx.draft_page)
    end

    test "the stored value is not rewritten, and the target appears once published", ctx do
      stored = CMS.get_post!(ctx.source.id, actor: ctx.admin).custom_fields
      assert length(stored[ctx.field]) == 2
      assert stored[ctx.single]["id"] == ctx.draft_page.id

      CMS.publish_page!(ctx.draft_page, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      body = build_conn() |> get("/api/content/post/#{ctx.source.slug}") |> json_response(200)
      ids = Enum.map(body["custom_fields"][ctx.field], & &1["id"])

      assert ids == [ctx.live_page.id, ctx.draft_page.id]
      assert body["custom_fields"][ctx.single]["title"] == "Secret draft"
    end
  end

  describe "JSON:API custom_fields" do
    defp api_get(path) do
      build_conn()
      |> put_req_header("accept", @accept)
      |> get(path)
      |> then(&{&1.status, Jason.decode!(&1.resp_body)})
    end

    test "an anonymous reader is not handed the draft snapshot", ctx do
      assert {200, body} = api_get("/api/json/posts/#{ctx.source.id}")
      custom = body["data"]["attributes"]["custom_fields"]

      assert [%{"id" => id}] = custom[ctx.field]
      assert id == ctx.live_page.id
      assert custom[ctx.single] == nil
      refute leaks?(body, ctx.draft_page)
    end

    test "nor on a list read", ctx do
      assert {200, body} = api_get("/api/json/posts/published?filter[id]=#{ctx.source.id}")
      refute leaks?(body, ctx.draft_page)
    end
  end

  describe "GraphQL customFields" do
    test "an anonymous reader is not handed the draft snapshot", ctx do
      query = """
      query ($slug: String!) { postBySlug(slug: $slug, locale: "en") { customFields } }
      """

      assert {:ok, %{data: %{"postBySlug" => %{"customFields" => custom}}}} =
               Absinthe.run(query, KilnCMSWeb.GraphqlSchema,
                 variables: %{"slug" => ctx.source.slug},
                 context: %{tenant: KilnCMS.Accounts.default_org_id()}
               )

      custom = if is_binary(custom), do: Jason.decode!(custom), else: custom

      assert [%{"id" => id}] = custom[ctx.field]
      assert id == ctx.live_page.id
      refute leaks?(custom, ctx.draft_page)
    end
  end

  test "an editor reads the stored value whole", ctx do
    custom = CMS.get_post!(ctx.source.id, actor: ctx.admin).custom_fields

    assert Enum.map(custom[ctx.field], & &1["id"]) == [ctx.live_page.id, ctx.draft_page.id]
    assert custom[ctx.single]["title"] == "Secret draft"
  end
end
