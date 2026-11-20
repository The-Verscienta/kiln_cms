defmodule KilnCMS.CMS.HeldListFieldTest do
  @moduledoc """
  A **held list** (#2680, `FieldDefinition.held_list?/1`): a `multiple` field
  whose type no longer takes lists — a plugin type whose `multiple?/0`
  stopped answering `true`. The fixture's `:rating` never takes lists, so a
  list of it is made the way an earlier plugin version left one: `multiple`
  set and arrays stored with raw SQL.

  Its stored lists are kept and served as they are, a write that changes one
  is refused on every surface, filtering and sorting on it is refused, the
  schema export describes it as a read-only array, and only an explicit
  narrowing (`narrow_held_list?`) makes it single — every other definition
  update keeps it a list (critic amendment A1).
  """
  # async: false — the GraphQL documents go through the shared schema and
  # sandbox, as in the other GraphQL custom-field tests.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  @accept "application/vnd.api+json"
  @schema KilnCMSWeb.GraphqlSchema

  doctest KilnCMS.CMS.FieldDefinition, only: [held_list?: 1]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "held-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  defp key(actor) do
    actor.id
    |> Accounts.mint_api_key!(
      "held-lists",
      DateTime.add(DateTime.utc_now(), 1, :day),
      %{access: :read_write},
      actor: actor
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  # What an earlier plugin version left: a `multiple` field of a type that
  # takes lists no more.
  defp hold!(field, attrs \\ %{}) do
    KilnCMS.Repo.query!(
      "UPDATE field_definitions SET multiple = true, required = $2 WHERE id = $1",
      [Ecto.UUID.dump!(field.id), Map.get(attrs, :required, false)]
    )

    CMS.get_field_definition!(field.id, authorize?: false)
  end

  defp store!(record, values) do
    KilnCMS.Repo.query!(
      "UPDATE posts SET custom_fields = custom_fields || $1 WHERE id = $2",
      [values, Ecto.UUID.dump!(record.id)]
    )
  end

  defp stored(id) do
    %{rows: [[fields]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [Ecto.UUID.dump!(id)])

    fields
  end

  defp reload(post), do: CMS.get_post!(post.id, authorize?: false)

  defp message!(result) do
    assert {:error, %Ash.Error.Invalid{} = error} = result
    Exception.message(error)
  end

  defp request(method, path, key, body \\ nil) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)
      |> put_req_header("authorization", "Bearer #{key}")

    conn = dispatch(conn, @endpoint, method, path, body && Jason.encode!(body))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp patch_json(post, custom_fields, key) do
    request(:patch, "/api/json/posts/#{post.id}", key, %{
      data: %{type: "post", id: post.id, attributes: %{custom_fields: custom_fields}}
    })
  end

  defp gql(query, variables, key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp gql_update(post, custom_fields, key) do
    gql(
      """
      mutation ($id: ID!, $input: UpdatePostInput!) {
        updatePost(id: $id, input: $input) { result { id } errors { message } }
      }
      """,
      %{id: post.id, input: %{customFields: Jason.encode!(custom_fields)}},
      key
    )
  end

  @message "no longer takes a list of values. The stored list is kept"

  setup do
    admin = admin()
    name = "score#{uniq()}"

    field =
      CMS.create_field_definition!(
        %{content_type: :post, name: name, label: "Score", field_type: :rating},
        actor: admin
      )

    motto =
      CMS.create_field_definition!(
        %{content_type: :post, name: "motto#{uniq()}", label: "Motto", field_type: :string},
        actor: admin
      )

    field = hold!(field)

    post =
      CMS.create_post!(
        %{title: "Held", slug: "held-#{uniq()}", custom_fields: %{motto.name => "first"}},
        actor: admin
      )

    store!(post, %{name => [3, 4]})

    %{admin: admin, field: field, name: name, motto: motto, post: reload(post)}
  end

  test "it is a held list", ctx do
    assert FieldDefinition.held_list?(ctx.field)
  end

  describe "a write" do
    test "that leaves it out keeps it", ctx do
      CMS.update_post!(ctx.post, %{custom_fields: %{ctx.motto.name => "second"}},
        actor: ctx.admin
      )

      assert stored(ctx.post.id) == %{ctx.motto.name => "second", ctx.name => [3, 4]}
    end

    test "re-sending the stored list passes; any other value is refused", ctx do
      assert {:ok, _} =
               CMS.update_post(ctx.post, %{custom_fields: %{ctx.name => [3, 4]}},
                 actor: ctx.admin
               )

      for value <- [[3], [5, 4], [4, 3], nil, "", []] do
        message =
          message!(
            CMS.update_post(reload(ctx.post), %{custom_fields: %{ctx.name => value}},
              actor: ctx.admin
            )
          )

        assert message =~ @message, inspect(value)
        assert message =~ "save the field as a single value"
      end

      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "a create naming it is refused", ctx do
      message =
        message!(
          CMS.create_post(
            %{title: "New", slug: "held-#{uniq()}", custom_fields: %{ctx.name => [3]}},
            actor: ctx.admin
          )
        )

      assert message =~ @message
    end

    test "over JSON:API: the stored list passes, a change is a 400 with the message", ctx do
      key = key(ctx.admin)

      assert {200, _} = patch_json(ctx.post, %{ctx.name => [3, 4]}, key)

      for value <- [[3], [5, 4], nil] do
        assert {400, %{"errors" => [error | _]}} = patch_json(ctx.post, %{ctx.name => value}, key)
        assert error["detail"] =~ @message
      end

      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "over GraphQL: the stored list passes, a change is refused", ctx do
      key = key(ctx.admin)

      assert gql_update(ctx.post, %{ctx.name => [3, 4]}, key)["data"]["updatePost"]["errors"] ==
               []

      for value <- [[3], [5, 4], nil] do
        body = gql_update(ctx.post, %{ctx.name => value}, key)
        assert [error | _] = body["data"]["updatePost"]["errors"]
        assert error["message"] =~ @message
      end

      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "a title-only update keeps it", ctx do
      CMS.update_post!(ctx.post, %{title: "Renamed"}, actor: ctx.admin)
      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end
  end

  describe "machinery that carries values" do
    test "a restore carries it", ctx do
      post = CMS.update_post!(ctx.post, %{title: "With score"}, actor: ctx.admin)

      version =
        CMS.list_post_versions!(authorize?: false, tenant: post.org_id)
        |> Enum.filter(&(&1.version_source_id == post.id))
        |> Enum.max_by(& &1.version_inserted_at, DateTime)

      post =
        CMS.update_post!(post, %{custom_fields: %{ctx.motto.name => "later"}}, actor: ctx.admin)

      CMS.restore_post_version!(post, %{version_id: version.id}, actor: ctx.admin)

      assert stored(post.id) == %{ctx.motto.name => "first", ctx.name => [3, 4]}
    end

    test "a working copy saved and published (a promote) carries it", ctx do
      live = CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)

      {:ok, saved} =
        CMS.save_post_working_copy(
          live,
          %{fields: %{"custom_fields" => %{ctx.motto.name => "held"}}},
          actor: ctx.admin,
          tenant: live.org_id
        )

      assert {:ok, _published} = CMS.publish_post_changes(saved, actor: ctx.admin)
      assert stored(live.id) == %{ctx.motto.name => "held", ctx.name => [3, 4]}
    end

    test "a duplicate carries it", ctx do
      {copy, _withheld} =
        KilnCMS.CMS.Duplication.duplicate_with_notes!(:post, ctx.post,
          actor: ctx.admin,
          tenant: ctx.post.org_id
        )

      assert stored(copy.id)[ctx.name] == [3, 4]
    end
  end

  describe "what it is not asked for" do
    test "required is not demanded of a held list", ctx do
      hold!(ctx.field, %{required: true})

      post =
        CMS.create_post!(%{title: "No score", slug: "held-#{uniq()}"}, actor: ctx.admin)

      assert {:ok, _} = CMS.publish_post(post, %{}, actor: ctx.admin)
    end

    test "a searchable held list stays in the search text", ctx do
      words =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "words#{uniq()}",
            label: "Words",
            field_type: :tokenless,
            searchable: true
          },
          actor: ctx.admin
        )

      hold!(words)
      store!(ctx.post, %{words.name => ["saffron", "cardamom"]})

      CMS.update_post!(reload(ctx.post), %{title: "Spiced"}, actor: ctx.admin)
      text = reload(ctx.post).search_text
      assert text =~ "saffron"
      assert text =~ "cardamom"
    end
  end

  describe "delivery" do
    test "a fired document serves the stored list", ctx do
      post = CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)

      %{values: fresh} = KilnCMS.Firing.CustomFields.resolve(post)
      assert fresh[ctx.name] == [3, 4]

      %{values: then} = KilnCMS.Firing.CustomFields.resolve(post, nil, recompute?: false)
      assert then[ctx.name] == [3, 4]
    end

    test "the schema export describes a read-only array of unconstrained items", ctx do
      post = KilnCMS.SchemaExport.json_schema(org_id: ctx.post.org_id)["$defs"]["content_post"]
      schema = inspect(post, limit: :infinity)
      assert schema =~ ctx.name

      [field] =
        post
        |> collect_properties()
        |> Enum.filter(fn {key, _schema} -> key == ctx.name end)
        |> Enum.map(&elem(&1, 1))

      assert field["type"] == ["array", "null"]
      assert field["items"] == %{}
      assert field["readOnly"] == true
    end
  end

  # Every `properties` map anywhere under `schema`.
  defp collect_properties(schema) when is_map(schema) do
    own = Map.get(schema, "properties", %{})
    own = if is_map(own), do: Enum.to_list(own), else: []
    own ++ Enum.flat_map(Map.values(schema), &collect_properties/1)
  end

  defp collect_properties(list) when is_list(list), do: Enum.flat_map(list, &collect_properties/1)
  defp collect_properties(_other), do: []

  describe "filtering and sorting" do
    @refusal "holds lists its field type (rating) no longer takes"

    test "every custom_filter operator and custom_sort is refused", ctx do
      for filter <- [
            %{ctx.name => "3"},
            %{ctx.name => %{"has" => [3]}},
            %{ctx.name => %{"count" => 2}},
            %{ctx.name => %{"null" => true}},
            %{"_not" => %{ctx.name => "3"}},
            %{"_or" => [%{ctx.name => "3"}]}
          ] do
        message = message!(CMS.list_posts(%{custom_filter: filter}, actor: ctx.admin))
        assert message =~ @refusal, inspect(filter)
      end

      assert message!(CMS.list_posts(%{custom_sort: ctx.name}, actor: ctx.admin)) =~ @refusal
    end

    test "over JSON:API it is a 400 naming the way out", ctx do
      key = key(ctx.admin)

      for query <- ["custom_filter[#{ctx.name}]=3", "custom_sort=#{ctx.name}"] do
        assert {400, %{"errors" => [error | _]}} =
                 request(:get, "/api/json/posts?#{query}", key)

        assert error["detail"] =~ @refusal
        assert error["detail"] =~ "until an admin saves it as a single value"
      end
    end

    test "over GraphQL customFilter and customWhere it is an error", ctx do
      CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)

      query = """
      query ($w: [CustomFieldCondition!], $f: JsonString) {
        publishedPosts(limit: 10, customWhere: $w, customFilter: $f) { results { id } }
      }
      """

      for vars <- [
            %{"f" => Jason.encode!(%{ctx.name => "3"})},
            %{"w" => [%{"name" => ctx.name, "int" => %{"eq" => 3}}]}
          ] do
        assert {:ok, %{errors: [_ | _] = errors}} =
                 Absinthe.run(query, @schema, variables: vars, context: %{})

        assert Enum.any?(errors, &(&1.message =~ @refusal)), inspect(errors)
      end
    end

    test "over MCP read_posts it is a tool error", ctx do
      key = key(ctx.admin)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("content-type", "application/json")
        |> post(
          "/mcp",
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "read_posts",
              arguments: %{input: %{custom_filter: %{ctx.name => "3"}}}
            }
          })
        )

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(conn, 200)

      assert text =~ @refusal
    end
  end

  describe "the definition (A1: only an explicit narrowing makes it single)" do
    test "an update with no narrow_held_list? keeps it a list, and the stored lists", ctx do
      assert {:ok, field} =
               CMS.update_field_definition(ctx.field, %{label: "Stars", multiple: false},
                 actor: ctx.admin
               )

      assert field.multiple
      assert FieldDefinition.held_list?(field)
      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "a reorder keeps it a list", ctx do
      {:ok, field} =
        CMS.update_field_definition(ctx.field, %{position: 7}, actor: ctx.admin)

      assert field.multiple
      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "renaming a field its condition reads keeps it a list", ctx do
      KilnCMS.Repo.query!(
        "UPDATE field_definitions SET visible_when = $1 WHERE id = $2",
        [%{"field" => ctx.motto.name, "op" => "not_empty"}, Ecto.UUID.dump!(ctx.field.id)]
      )

      CMS.update_field_definition!(ctx.motto, %{name: "slogan#{uniq()}"}, actor: ctx.admin)

      field = CMS.get_field_definition!(ctx.field.id, authorize?: false)
      assert field.multiple
      assert field.visible_when["field"] =~ "slogan"
      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "a field sync import changing its label keeps it a list", ctx do
      {:ok, doc} = CMS.FieldSync.export(actor: ctx.admin)

      doc =
        update_in(
          doc,
          ["owners", Access.all(), "fields", Access.filter(&(&1["name"] == ctx.name))],
          &Map.put(&1, "label", "Stars")
        )

      assert {:ok, _report} = CMS.FieldSync.import_doc(doc, actor: ctx.admin, apply?: true)

      field = CMS.get_field_definition!(ctx.field.id, authorize?: false)
      assert field.label == "Stars"
      assert field.multiple
      assert stored(ctx.post.id)[ctx.name] == [3, 4]
    end

    test "a field sync import that narrows it is blocked as data loss", ctx do
      {:ok, doc} = CMS.FieldSync.export(actor: ctx.admin)

      doc =
        update_in(
          doc,
          ["owners", Access.all(), "fields", Access.filter(&(&1["name"] == ctx.name))],
          &Map.put(&1, "multiple", false)
        )

      assert {:error, report} = CMS.FieldSync.import_doc(doc, actor: ctx.admin, apply?: true)
      assert Enum.any?(report.blocked, &(&1.reason =~ "keeps only its first item"))
      assert CMS.get_field_definition!(ctx.field.id, authorize?: false).multiple

      assert {:ok, _report} =
               CMS.FieldSync.import_doc(doc,
                 actor: ctx.admin,
                 apply?: true,
                 allow_data_loss?: true
               )

      refute CMS.get_field_definition!(ctx.field.id, authorize?: false).multiple
      assert stored(ctx.post.id)[ctx.name] == 3
    end

    test "narrow_held_list?: true narrows it, keeping each record's first item", ctx do
      {:ok, field} =
        CMS.update_field_definition(ctx.field, %{narrow_held_list?: true}, actor: ctx.admin)

      refute field.multiple
      refute FieldDefinition.held_list?(field)
      assert stored(ctx.post.id)[ctx.name] == 3
    end
  end
end
