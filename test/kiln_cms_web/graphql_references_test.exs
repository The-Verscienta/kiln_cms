defmodule KilnCMSWeb.GraphqlReferencesTest do
  @moduledoc """
  Workstream R7 of `docs/relationships-plan.md`: every content type's
  `references(field:)` and `referencedBy` fields, typed through the
  `ContentRecord` interface.

  The both-ends rule is the one the edge table already enforces: a reader
  sees a target (or a source) only if they could read it directly. Drafts on
  either end are invisible to an anonymous reader and visible to an editor.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gref-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "gref-#{System.unique_integer([:positive])}"

  defp run(query, variables, actor \\ nil),
    do: Absinthe.run(query, @schema, variables: variables, context: %{actor: actor})

  defp page!(admin, title), do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
  defp post!(admin, title), do: CMS.create_post!(%{title: title, slug: slug()}, actor: admin)
  defp publish_page!(page, admin), do: CMS.publish_page!(page, %{}, actor: admin)
  defp publish_post!(post, admin), do: CMS.publish_post!(post, %{}, actor: admin)

  defp ref(record, type), do: %{"id" => record.id, "type" => type}

  # A post field linking to pages and posts, many-valued.
  defp field!(admin) do
    name = "linked_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: name,
        label: "Linked",
        field_type: :reference,
        target_types: ["page", "post"],
        multiple: true
      },
      actor: admin
    )

    name
  end

  defp referrer!(admin, field, targets) do
    CMS.create_post!(
      %{
        title: "Referrer #{System.unique_integer([:positive])}",
        slug: slug(),
        custom_fields: %{field => targets}
      },
      actor: admin
    )
  end

  @references """
  query ($slug: String!, $field: String!, $limit: Int, $offset: Int) {
    postBySlug(slug: $slug, locale: "en") {
      references(field: $field, limit: $limit, offset: $offset) {
        position
        link
        target {
          __typename
          id
          title
          state
          ... on Post { excerpt }
        }
      }
    }
  }
  """

  @referenced_by """
  query ($slug: String!, $field: String, $sourceType: String) {
    pageBySlug(slug: $slug, locale: "en") {
      referencedBy(field: $field, sourceType: $sourceType) {
        field
        position
        source { __typename id title }
      }
    }
  }
  """

  setup do
    admin = user(:admin)
    field = field!(admin)

    live_page = admin |> page!("Live page") |> publish_page!(admin)
    draft_page = page!(admin, "Draft page")
    live_post = admin |> post!("Live post") |> publish_post!(admin)

    source =
      admin
      |> referrer!(field, [
        ref(live_page, "page"),
        ref(draft_page, "page"),
        ref(live_post, "post")
      ])
      |> publish_post!(admin)

    %{
      admin: admin,
      field: field,
      source: source,
      live_page: live_page,
      draft_page: draft_page,
      live_post: live_post
    }
  end

  defp references(source, field, actor, extra \\ %{}) do
    assert {:ok, %{data: %{"postBySlug" => %{"references" => rows}}} = result} =
             run(@references, Map.merge(%{"slug" => source.slug, "field" => field}, extra), actor)

    refute Map.has_key?(result, :errors)
    rows
  end

  describe "references" do
    test "an anonymous reader gets the published targets, typed, in the field's order", ctx do
      rows = references(ctx.source, ctx.field, nil)

      assert [
               %{"position" => 0, "target" => %{"__typename" => "Page"} = page},
               %{"position" => 2, "target" => %{"__typename" => "Post"} = post}
             ] = rows

      assert page["id"] == ctx.live_page.id
      assert page["title"] == "Live page"
      assert post["id"] == ctx.live_post.id
      assert Map.has_key?(post, "excerpt")
      refute Map.has_key?(page, "excerpt")
      assert Enum.all?(rows, &(&1["link"] == %{}))
    end

    test "an editor also sees the draft target", ctx do
      rows = references(ctx.source, ctx.field, user(:editor))

      assert Enum.map(rows, & &1["target"]["id"]) ==
               [ctx.live_page.id, ctx.draft_page.id, ctx.live_post.id]

      assert Enum.at(rows, 1)["target"]["state"] == "draft"
    end

    test "limit and offset page over the readable targets only", ctx do
      assert [%{"target" => %{"id" => id}}] =
               references(ctx.source, ctx.field, nil, %{"limit" => 1, "offset" => 1})

      # The draft at position 1 is not counted for an anonymous reader.
      assert id == ctx.live_post.id

      assert [%{"target" => %{"id" => draft}}] =
               references(ctx.source, ctx.field, user(:editor), %{"limit" => 1, "offset" => 1})

      assert draft == ctx.draft_page.id
    end

    test "a field the record does not have is an empty list", ctx do
      assert references(ctx.source, "no_such_field", nil) == []
    end

    test "a dynamic-type target is an Entry", ctx do
      definition =
        CMS.create_type_definition!(
          %{name: "gr#{System.unique_integer([:positive])}", label: "Product"},
          actor: ctx.admin
        )

      name = "made_of_#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: name,
          label: "Made of",
          field_type: :reference,
          target_type: definition.name
        },
        actor: ctx.admin
      )

      entry =
        definition.name
        |> CMS.ContentTypes.create!(%{title: "Widget", slug: slug()}, actor: ctx.admin)
        |> CMS.publish_entry!(%{}, actor: ctx.admin)

      source =
        CMS.create_post!(
          %{title: "Uses widget", slug: slug(), custom_fields: %{name => entry.id}},
          actor: ctx.admin
        )
        |> publish_post!(ctx.admin)

      query = """
      query ($slug: String!, $field: String!) {
        postBySlug(slug: $slug, locale: "en") {
          references(field: $field) { target { __typename title ... on Entry { typeName } } }
        }
      }
      """

      assert {:ok, %{data: %{"postBySlug" => %{"references" => [%{"target" => target}]}}}} =
               run(query, %{"slug" => source.slug, "field" => name})

      assert target == %{
               "__typename" => "Entry",
               "title" => "Widget",
               "typeName" => definition.name
             }
    end
  end

  describe "referencedBy" do
    setup ctx do
      draft_source = referrer!(ctx.admin, ctx.field, [ref(ctx.live_page, "page")])
      %{draft_source: draft_source}
    end

    defp referenced_by(page, actor, extra \\ %{}) do
      assert {:ok, %{data: %{"pageBySlug" => %{"referencedBy" => rows}}} = result} =
               run(@referenced_by, Map.merge(%{"slug" => page.slug}, extra), actor)

      refute Map.has_key?(result, :errors)
      rows
    end

    test "an anonymous reader never sees a draft source", ctx do
      assert [%{"field" => field, "position" => 0, "source" => source}] =
               referenced_by(ctx.live_page, nil)

      assert field == ctx.field

      assert source == %{
               "__typename" => "Post",
               "id" => ctx.source.id,
               "title" => ctx.source.title
             }
    end

    test "an editor sees the draft source too", ctx do
      ids = ctx.live_page |> referenced_by(user(:editor)) |> Enum.map(& &1["source"]["id"])
      assert Enum.sort(ids) == Enum.sort([ctx.source.id, ctx.draft_source.id])
    end

    test "field and sourceType narrow the list", ctx do
      assert [_] =
               referenced_by(ctx.live_page, nil, %{"field" => ctx.field, "sourceType" => "post"})

      assert [] = referenced_by(ctx.live_page, nil, %{"sourceType" => "page"})
      assert [] = referenced_by(ctx.live_page, nil, %{"field" => "other_field"})
    end

    test "a draft target's referencedBy is unreachable anonymously, and works for an editor",
         ctx do
      assert {:ok, %{data: %{"pageBySlug" => nil}}} =
               run(@referenced_by, %{"slug" => ctx.draft_page.slug})

      editor_query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          references(field: "#{ctx.field}") {
            target { id referencedBy { source { id } } }
          }
        }
      }
      """

      assert {:ok, %{data: %{"postBySlug" => %{"references" => rows}}}} =
               run(editor_query, %{"slug" => ctx.source.slug}, user(:editor))

      draft = Enum.find(rows, &(&1["target"]["id"] == ctx.draft_page.id))
      assert [%{"source" => %{"id" => id}}] = draft["target"]["referencedBy"]
      assert id == ctx.source.id
    end
  end

  describe "referencedBy(inverse:)" do
    setup ctx do
      name = "used_in_#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: name,
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          inverse_label: "Posts using this page",
          inverse_name: name <> "_by"
        },
        actor: ctx.admin
      )

      source =
        ctx.admin
        |> referrer!(name, [ref(ctx.live_page, "page")])
        |> publish_post!(ctx.admin)

      %{inverse: name <> "_by", inverse_field: name, inverse_source: source}
    end

    @by_inverse """
    query ($slug: String!, $inverse: String!, $field: String) {
      pageBySlug(slug: $slug, locale: "en") {
        referencedBy(inverse: $inverse, field: $field) { field source { id } }
      }
    }
    """

    test "names the reference field and source type in one argument", ctx do
      assert {:ok, %{data: %{"pageBySlug" => %{"referencedBy" => rows}}}} =
               run(@by_inverse, %{"slug" => ctx.live_page.slug, "inverse" => ctx.inverse})

      field = ctx.inverse_field
      assert [%{"field" => ^field, "source" => %{"id" => id}}] = rows
      assert id == ctx.inverse_source.id
    end

    test "a name the type has no reverse field for lists nothing", ctx do
      assert {:ok, %{data: %{"pageBySlug" => %{"referencedBy" => []}}}} =
               run(@by_inverse, %{"slug" => ctx.live_page.slug, "inverse" => "nope"})

      # The reverse field belongs to the page side, not to posts.
      query = """
      query ($slug: String!, $inverse: String!) {
        postBySlug(slug: $slug, locale: "en") { referencedBy(inverse: $inverse) { field } }
      }
      """

      assert {:ok, %{data: %{"postBySlug" => %{"referencedBy" => []}}}} =
               run(query, %{"slug" => ctx.live_post.slug, "inverse" => ctx.inverse})
    end

    test "is not combined with field or sourceType", ctx do
      assert {:ok, %{errors: [%{message: message}]}} =
               run(@by_inverse, %{
                 "slug" => ctx.live_page.slug,
                 "inverse" => ctx.inverse,
                 "field" => ctx.inverse_field
               })

      assert message =~ "not both"
    end
  end

  describe "link" do
    test "passes a link field's stored value through as JSON", ctx do
      name = "recipe_#{System.unique_integer([:positive])}"

      field =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: name,
            label: "Recipe",
            field_type: :reference,
            target_type: "page",
            multiple: true
          },
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{link_of_id: field.id, name: "quantity", label: "Quantity", field_type: :integer},
        actor: ctx.admin
      )

      source =
        CMS.create_post!(
          %{
            title: "Linked recipe",
            slug: slug(),
            custom_fields: %{
              name => [%{"id" => ctx.live_page.id, "link" => %{"quantity" => "500"}}]
            }
          },
          actor: ctx.admin
        )
        |> publish_post!(ctx.admin)

      assert [%{"link" => %{"quantity" => 500}, "target" => %{"id" => id}}] =
               references(source, name, nil)

      assert id == ctx.live_page.id
    end
  end

  describe "batching" do
    test "a list of records reads its edges once and each target type once", ctx do
      for _ <- 1..2 do
        ctx.admin
        |> referrer!(ctx.field, [ref(ctx.live_page, "page"), ref(ctx.live_post, "post")])
        |> publish_post!(ctx.admin)
      end

      query = """
      query {
        publishedPosts(limit: 10) {
          results { id references(field: "#{ctx.field}") { target { id title } } }
        }
      }
      """

      sources = count_queries(fn -> assert {:ok, %{data: _}} = run(query, %{}) end)

      reads = Enum.frequencies(sources)

      # Three parents, six edges: one edge read, and per target type one read
      # for the edge gate (`LinkEndsReadable`) plus one for the targets. Posts
      # add the `publishedPosts` read itself.
      assert reads["content_links"] == 1
      assert reads["pages"] == 2
      assert reads["posts"] == 3
    end
  end

  describe "query cost" do
    test "an unlimited references list is priced at five rows, so deep nesting is refused", ctx do
      query = """
      query ($slug: String!) {
        postBySlug(slug: $slug, locale: "en") {
          references(field: "#{ctx.field}") { target { id
            references(field: "#{ctx.field}") { target { id
              references(field: "#{ctx.field}") { target { id title slug } }
            } }
          } }
        }
      }
      """

      # The limits `/gql` and `/ws/gql` pin (`KilnCMSWeb.GraphqlLimits`).
      priced = fn document ->
        Absinthe.run(
          document,
          @schema,
          [variables: %{"slug" => ctx.source.slug}] ++ KilnCMSWeb.GraphqlLimits.options()
        )
      end

      assert {:ok, %{errors: [%{message: message} | _]}} = priced.(query)
      assert message =~ "complexity"

      cheap =
        String.replace(
          query,
          ~s|references(field: "#{ctx.field}")|,
          ~s|references(field: "#{ctx.field}", limit: 1)|
        )

      assert {:ok, %{data: _} = result} = priced.(cheap)
      refute Map.has_key?(result, :errors)
    end
  end

  # Every Ecto query source (table) the function's process tree selects from.
  defp count_queries(fun) do
    parent = self()
    handler = "gref-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == parent or parent in (Process.get(:"$callers") || []),
          do: send(parent, {:query_source, meta[:source]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:query_source, source} -> drain([source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
