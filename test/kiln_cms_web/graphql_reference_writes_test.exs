defmodule KilnCMSWeb.GraphqlReferenceWritesTest do
  @moduledoc """
  Workstream R8 of `docs/relationships-plan.md`: `add<Type>References`,
  `remove<Type>References` and `move<Type>Reference`.

  Each is an update of the source record (D23), so what these tests pin is
  that the update's rules come along: its policies and API-key scope, the
  lock, the field's own coercion (link fields, bounds), and the edges that
  follow the stored value.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "grw-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "grw-#{System.unique_integer([:positive])}"

  defp run(query, variables, actor),
    do: Absinthe.run(query, @schema, variables: variables, context: %{actor: actor})

  defp page!(admin, title),
    do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)

  defp field!(admin, attrs \\ %{}) do
    name = "linked_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Linked",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post!(admin, custom_fields \\ %{}),
    do:
      CMS.create_post!(%{title: "Source", slug: slug(), custom_fields: custom_fields},
        actor: admin
      )

  defp ids(post, field) do
    post.custom_fields
    |> Map.get(field, [])
    |> List.wrap()
    |> Enum.map(& &1["id"])
  end

  defp reload(post, admin), do: CMS.get_post!(post.id, actor: admin)

  @add """
  mutation ($id: ID!, $field: String!, $targets: [ReferenceTargetInput!]!,
            $position: ReferencePositionInput, $lock: Int) {
    addPostReferences(id: $id, field: $field, targets: $targets, position: $position,
                      expectedLockVersion: $lock) {
      result { id lockVersion customFields references(field: $field) { position link target { id } } }
      errors { message code fields }
    }
  }
  """

  @remove """
  mutation ($id: ID!, $field: String!, $targets: [ID!]!) {
    removePostReferences(id: $id, field: $field, targets: $targets) {
      result { id }
      errors { message code }
    }
  }
  """

  @move """
  mutation ($id: ID!, $field: String!, $target: ID!, $position: ReferencePositionInput!) {
    movePostReference(id: $id, field: $field, target: $target, position: $position) {
      result { id }
      errors { message code }
    }
  }
  """

  defp add(post, field, targets, actor, extra \\ %{}) do
    vars =
      Map.merge(
        %{"id" => post.id, "field" => field, "targets" => Enum.map(targets, &target/1)},
        extra
      )

    {:ok, %{data: %{"addPostReferences" => payload}}} = run(@add, vars, actor)
    payload
  end

  defp target(%{id: id}), do: %{"id" => id}
  defp target(%{"link" => link} = given), do: %{given | "link" => Jason.encode!(link)}
  defp target(%{} = given), do: given

  defp remove(post, field, ids, actor) do
    {:ok, %{data: %{"removePostReferences" => payload}}} =
      run(@remove, %{"id" => post.id, "field" => field, "targets" => ids}, actor)

    payload
  end

  defp move(post, field, id, position, actor) do
    {:ok, %{data: %{"movePostReference" => payload}}} =
      run(
        @move,
        %{"id" => post.id, "field" => field, "target" => id, "position" => position},
        actor
      )

    payload
  end

  setup do
    admin = user(:admin)
    [a, b, c, d] = for title <- ~w(A B C D), do: page!(admin, title)
    %{admin: admin, a: a, b: b, c: c, d: d}
  end

  describe "addPostReferences" do
    test "connects in order, at the end by default, and returns the typed result", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)

      assert %{"errors" => [], "result" => result} = add(post, field, [ctx.a, ctx.b], ctx.admin)

      assert Enum.map(result["references"], & &1["target"]["id"]) == [ctx.a.id, ctx.b.id]
      assert Enum.map(result["references"], & &1["position"]) == [0, 1]

      add(post, field, [ctx.c], ctx.admin)
      assert ids(reload(post, ctx.admin), field) == [ctx.a.id, ctx.b.id, ctx.c.id]
    end

    test "start, before and after place the block", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin, %{})
      add(post, field, [ctx.a, ctx.b], ctx.admin)

      add(post, field, [ctx.c], ctx.admin, %{"position" => %{"start" => true}})
      assert ids(reload(post, ctx.admin), field) == [ctx.c.id, ctx.a.id, ctx.b.id]

      add(post, field, [ctx.d], ctx.admin, %{"position" => %{"after" => ctx.a.id}})
      assert ids(reload(post, ctx.admin), field) == [ctx.c.id, ctx.a.id, ctx.d.id, ctx.b.id]

      remove(post, field, [ctx.d.id], ctx.admin)
      add(post, field, [ctx.d], ctx.admin, %{"position" => %{"before" => ctx.c.id}})
      assert ids(reload(post, ctx.admin), field) == [ctx.d.id, ctx.c.id, ctx.a.id, ctx.b.id]
    end

    test "adding a connected record moves it, so a retry converges", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a, ctx.b, ctx.c], ctx.admin)

      add(post, field, [ctx.a], ctx.admin)
      add(post, field, [ctx.a], ctx.admin)
      assert ids(reload(post, ctx.admin), field) == [ctx.b.id, ctx.c.id, ctx.a.id]
    end

    test "the edges follow, with their positions", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a, ctx.b], ctx.admin)
      add(post, field, [ctx.b], ctx.admin, %{"position" => %{"start" => true}})

      edges =
        post.id
        |> CMS.list_reference_links!(actor: ctx.admin)
        |> Enum.filter(&(&1.field == field))
        |> Enum.sort_by(& &1.position)

      assert Enum.map(edges, &{&1.target_id, &1.position}) == [{ctx.b.id, 0}, {ctx.a.id, 1}]
    end

    test "an anchor that isn't connected, or two positions, is refused", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a], ctx.admin)

      assert %{"result" => nil, "errors" => [error]} =
               add(post, field, [ctx.b], ctx.admin, %{"position" => %{"after" => ctx.c.id}})

      assert error["message"] =~ "is not connected"

      assert %{"result" => nil, "errors" => [error]} =
               add(post, field, [ctx.b], ctx.admin, %{
                 "position" => %{"start" => true, "after" => ctx.a.id}
               })

      assert error["message"] =~ "exactly one of"
      assert ids(reload(post, ctx.admin), field) == [ctx.a.id]
    end

    test "a target that doesn't resolve fails through the field's own coercion", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)

      assert %{"result" => nil, "errors" => [_ | _]} =
               add(post, field, [%{"id" => Ash.UUID.generate()}], ctx.admin)

      assert ids(reload(post, ctx.admin), field) == []
    end

    test "max_items still bounds the list", ctx do
      %{name: field} = field!(ctx.admin, %{max_items: 2})
      post = post!(ctx.admin)
      add(post, field, [ctx.a, ctx.b], ctx.admin)

      assert %{"errors" => [error]} = add(post, field, [ctx.c], ctx.admin)
      assert error["message"] =~ "at most 2"
    end

    test "max_sources (R1b) refuses a connection to a full target, and allows a move", ctx do
      %{name: field} = field!(ctx.admin, %{max_sources: 1})
      first = post!(ctx.admin)
      second = post!(ctx.admin)

      assert %{"errors" => []} = add(first, field, [ctx.a, ctx.b], ctx.admin)

      assert %{"result" => nil, "errors" => [error]} = add(second, field, [ctx.a], ctx.admin)
      assert error["message"] =~ "is full"
      assert ids(reload(second, ctx.admin), field) == []

      # Reordering a target the source already holds is never refused.
      assert %{"errors" => []} = move(first, field, ctx.b.id, %{"start" => true}, ctx.admin)
      assert ids(reload(first, ctx.admin), field) == [ctx.b.id, ctx.a.id]
    end

    test "an unknown field, or one that isn't a reference, is refused", ctx do
      post = post!(ctx.admin)

      assert %{"errors" => [error]} = add(post, "nope", [ctx.a], ctx.admin)
      assert error["message"] =~ "is not a custom field"

      CMS.create_field_definition!(
        %{content_type: :post, name: "plain_text", label: "Plain", field_type: :string},
        actor: ctx.admin
      )

      assert %{"errors" => [error]} = add(post, "plain_text", [ctx.a], ctx.admin)
      assert error["message"] =~ "is not a reference field"
    end
  end

  describe "link fields" do
    setup ctx do
      field = field!(ctx.admin)

      CMS.create_field_definition!(
        %{link_of_id: field.id, name: "quantity", label: "Quantity", field_type: :integer},
        actor: ctx.admin
      )

      CMS.create_field_definition!(
        %{link_of_id: field.id, name: "note", label: "Note", field_type: :string},
        actor: ctx.admin
      )

      %{field: field.name}
    end

    test "link values are set, validated, and merged when a connection is re-added", ctx do
      post = post!(ctx.admin)

      assert %{"errors" => []} =
               add(
                 post,
                 ctx.field,
                 [%{"id" => ctx.a.id, "link" => %{"quantity" => 2, "note" => "x"}}],
                 ctx.admin
               )

      assert %{"errors" => [error]} =
               add(
                 post,
                 ctx.field,
                 [%{"id" => ctx.b.id, "link" => %{"quantity" => "lots"}}],
                 ctx.admin
               )

      assert error["message"] =~ "whole number"

      assert %{"errors" => [], "result" => result} =
               add(
                 post,
                 ctx.field,
                 [%{"id" => ctx.a.id, "link" => %{"quantity" => 3}}],
                 ctx.admin
               )

      assert [%{"link" => %{"quantity" => 3, "note" => "x"}}] = result["references"]

      assert [%{"link" => %{"quantity" => 3, "note" => "x"}}] =
               reload(post, ctx.admin).custom_fields[ctx.field]
    end
  end

  describe "removePostReferences" do
    test "disconnects, and ignores ids the field does not hold", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a, ctx.b, ctx.c], ctx.admin)

      assert %{"errors" => []} = remove(post, field, [ctx.b.id, ctx.d.id], ctx.admin)
      assert ids(reload(post, ctx.admin), field) == [ctx.a.id, ctx.c.id]

      assert [_, _] =
               post.id
               |> CMS.list_reference_links!(actor: ctx.admin)
               |> Enum.filter(&(&1.field == field))
    end
  end

  describe "movePostReference" do
    test "moves one connected record", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a, ctx.b, ctx.c], ctx.admin)

      assert %{"errors" => []} = move(post, field, ctx.c.id, %{"before" => ctx.a.id}, ctx.admin)
      assert ids(reload(post, ctx.admin), field) == [ctx.c.id, ctx.a.id, ctx.b.id]

      assert %{"errors" => []} = move(post, field, ctx.c.id, %{"end" => true}, ctx.admin)
      assert ids(reload(post, ctx.admin), field) == [ctx.a.id, ctx.b.id, ctx.c.id]
    end

    test "a record that isn't connected can't be moved", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      add(post, field, [ctx.a], ctx.admin)

      assert %{"errors" => [error]} = move(post, field, ctx.b.id, %{"start" => true}, ctx.admin)
      assert error["message"] =~ "is not connected"
    end
  end

  describe "a single-valued field" do
    test "add sets it, remove clears it, move is refused", ctx do
      %{name: field} = field!(ctx.admin, %{multiple: false})
      post = post!(ctx.admin)

      assert %{"errors" => []} = add(post, field, [ctx.a], ctx.admin)
      assert %{"id" => id} = reload(post, ctx.admin).custom_fields[field]
      assert id == ctx.a.id

      assert %{"errors" => []} = add(post, field, [ctx.b], ctx.admin)
      assert reload(post, ctx.admin).custom_fields[field]["id"] == ctx.b.id

      assert %{"errors" => [error]} = add(post, field, [ctx.a, ctx.c], ctx.admin)
      assert error["message"] =~ "exactly one"

      assert %{"errors" => [error]} = move(post, field, ctx.b.id, %{"start" => true}, ctx.admin)
      assert error["message"] =~ "no order"

      assert %{"errors" => []} = remove(post, field, [ctx.b.id], ctx.admin)
      assert is_nil(reload(post, ctx.admin).custom_fields[field])
    end
  end

  describe "it is the record's update" do
    test "expectedLockVersion refuses a stale write", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      stale = post.lock_version
      CMS.update_post!(post, %{title: "Edited since"}, actor: ctx.admin)

      assert %{"result" => nil, "errors" => [error]} =
               add(post, field, [ctx.a], ctx.admin, %{"lock" => stale})

      assert error["code"] == "precondition_failed"

      assert %{"errors" => [], "result" => %{"lockVersion" => version}} =
               add(post, field, [ctx.a], ctx.admin, %{"lock" => stale + 1})

      assert version == stale + 2
    end

    test "a viewer may not write, and an editor scoped away from the type may not either", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)

      for actor <- [user(:viewer), user(:editor, %{editable_types: ["page"]})] do
        assert %{"result" => nil, "errors" => [_ | _]} = add(post, field, [ctx.a], actor)
      end

      assert ids(reload(post, ctx.admin), field) == []
      assert %{"errors" => []} = add(post, field, [ctx.a], user(:editor))
    end

    test "a published record's write writes a version and keeps it published", ctx do
      %{name: field} = field!(ctx.admin)
      post = ctx.admin |> post!() |> then(&CMS.publish_post!(&1, %{}, actor: ctx.admin))

      versions = fn ->
        ctx.admin
        |> then(&CMS.list_post_versions!(actor: &1))
        |> Enum.count(&(&1.version_source_id == post.id))
      end

      before = versions.()

      assert %{"errors" => []} = add(post, field, [ctx.a], ctx.admin)

      assert reload(post, ctx.admin).state == :published
      assert versions.() > before
    end
  end

  describe "a dynamic type" do
    test "addEntryReferences writes an entry's field through update_entry", ctx do
      name = "grwtype#{System.unique_integer([:positive])}"
      type = CMS.create_type_definition!(%{name: name, label: "Recipe"}, actor: ctx.admin)

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "pages",
          label: "Pages",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: ctx.admin
      )

      entry =
        KilnCMS.CMS.ContentTypes.create!(name, %{title: "Soup", slug: slug()}, actor: ctx.admin)

      query = """
      mutation ($id: ID!, $targets: [ReferenceTargetInput!]!) {
        addEntryReferences(id: $id, field: "pages", targets: $targets) {
          result { id }
          errors { message }
        }
      }
      """

      assert {:ok, %{data: %{"addEntryReferences" => %{"errors" => []}}}} =
               run(query, %{"id" => entry.id, "targets" => [%{"id" => ctx.a.id}]}, ctx.admin)

      assert [%{"id" => id}] = CMS.get_entry!(entry.id, actor: ctx.admin).custom_fields["pages"]
      assert id == ctx.a.id
    end
  end

  describe "over /gql with an API key" do
    defp key(owner, access) do
      owner.id
      |> Accounts.mint_api_key!(
        "refs",
        DateTime.add(DateTime.utc_now(), 1, :day),
        %{access: access},
        actor: user(:admin)
      )
      |> Ash.Resource.get_metadata(:plaintext_api_key)
    end

    defp gql(conn, key, vars, headers \\ []) do
      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> put_req_header("content-type", "application/json")
      |> post("/gql", Jason.encode!(%{query: @add, variables: vars}))
      |> json_response(200)
    end

    test "a read-only key is refused; a read_write key writes", %{conn: conn} = ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      vars = %{"id" => post.id, "field" => field, "targets" => [%{"id" => ctx.a.id}]}

      assert %{"data" => %{"addPostReferences" => %{"result" => nil, "errors" => [_ | _]}}} =
               gql(conn, key(ctx.admin, :read), vars)

      assert %{"data" => %{"addPostReferences" => %{"errors" => []}}} =
               gql(build_conn(), key(ctx.admin, :read_write), vars)

      assert ids(reload(post, ctx.admin), field) == [ctx.a.id]
    end

    test "an Idempotency-Key replays the first answer instead of writing twice", ctx do
      %{name: field} = field!(ctx.admin)
      post = post!(ctx.admin)
      key = key(ctx.admin, :read_write)
      vars = %{"id" => post.id, "field" => field, "targets" => [%{"id" => ctx.a.id}]}

      first = gql(build_conn(), key, vars, [{"idempotency-key", "refs-1"}])
      second = gql(build_conn(), key, vars, [{"idempotency-key", "refs-1"}])

      assert first == second
      assert reload(post, ctx.admin).lock_version == post.lock_version + 1
    end
  end
end
