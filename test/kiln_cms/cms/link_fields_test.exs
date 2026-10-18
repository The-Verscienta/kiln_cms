defmodule KilnCMS.CMS.LinkFieldsTest do
  @moduledoc """
  Workstream R3 of `docs/relationships-plan.md`: **link fields** — typed data
  on each connection a `:reference` field makes (`FieldDefinition` rows with
  `link_of_id`). Covers the definition rules, the write-time coercion, the
  snapshot's added `"link"` key, its copy on the edge's `metadata`, rename and
  purge of a link field in both copies, `custom_filter[field.link.name]` with
  its both-ends read gate, and the schema export.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.SchemaExport

  require Ash.Query

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "link-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "link-#{System.unique_integer([:positive])}"

  defp page!(admin, title, opts \\ []) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)

    if Keyword.get(opts, :publish, false),
      do: CMS.publish_page!(page, %{}, actor: admin),
      else: page
  end

  defp reference!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "ingredients_#{System.unique_integer([:positive])}",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp link!(admin, parent, attrs) do
    CMS.create_field_definition!(Map.put(attrs, :link_of_id, parent.id), actor: admin)
  end

  defp post!(admin, fields, opts \\ []) do
    post = CMS.create_post!(%{title: "Recipe", slug: slug(), custom_fields: fields}, actor: admin)

    if Keyword.get(opts, :publish, false),
      do: CMS.publish_post!(post, %{}, actor: admin),
      else: post
  end

  defp update_post(post, fields, admin),
    do: CMS.update_post(post, %{custom_fields: fields}, actor: admin)

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  defp edges(source, field) do
    ContentLink
    |> Ash.Query.filter(source_id == ^source.id and kind == :reference and field == ^field)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.target_id, &1.metadata})
  end

  defp links(value), do: Enum.map(value, &Map.get(&1, "link"))

  setup do
    admin = user(:admin)
    field = reference!(admin)

    quantity =
      link!(admin, field, %{name: "quantity", label: "Quantity", field_type: :integer})

    role =
      link!(admin, field, %{
        name: "role",
        label: "Role",
        field_type: :select,
        options: ["main", "garnish"],
        default: "main",
        position: 1
      })

    %{admin: admin, field: field, name: field.name, quantity: quantity, role: role}
  end

  describe "the definition" do
    test "link fields load with their reference, in order, and are not fields of the type",
         %{admin: admin, field: field} do
      definitions = CMS.field_definitions_for!(:post, actor: admin)

      refute Enum.any?(definitions, &(&1.link_of_id == field.id))

      parent = Enum.find(definitions, &(&1.id == field.id))
      assert parent |> FieldDefinition.link_fields() |> Enum.map(& &1.name) == ~w(quantity role)
    end

    test "a link field belongs to a top-level reference field only", %{admin: admin, field: field} do
      text =
        CMS.create_field_definition!(
          %{content_type: :post, name: "note_#{System.unique_integer([:positive])}", label: "N"},
          actor: admin
        )

      assert error_message!(fn ->
               link!(admin, text, %{name: "x", label: "X", field_type: :string})
             end) =~ "link fields can only be added to a reference field"

      [quantity | _] =
        CMS.get_field_definition!(field.id, actor: admin, load: [:link_fields]).link_fields

      assert error_message!(fn ->
               link!(admin, quantity, %{name: "x", label: "X", field_type: :string})
             end) =~ "link fields can only be added to a reference field"

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{
                   content_type: :post,
                   link_of_id: field.id,
                   name: "x",
                   label: "X",
                   field_type: :string
                 },
                 actor: admin
               )
             end) =~ "belongs to its reference field"
    end

    test "only the plain types; record-level options are cleared", %{admin: admin, field: field} do
      for type <- [:reference, :media, :computed, :geolocation] do
        assert error_message!(fn ->
                 link!(admin, field, %{name: "x_#{type}", label: "X", field_type: type})
               end) =~ "can't be used for details on a connection"
      end

      link =
        link!(admin, field, %{
          name: "note",
          label: "Note",
          field_type: :string,
          searchable: true,
          names_record: true,
          localization: :shared
        })

      assert %{searchable: false, names_record: false, localization: :localized} = link
    end

    test "a link field stays on its reference", %{admin: admin, quantity: quantity} do
      other = reference!(admin)

      assert error_message!(fn ->
               CMS.update_field_definition!(quantity, %{link_of_id: other.id}, actor: admin)
             end) =~ "stays on the reference field"
    end

    test "link-field names are unique per reference, not across them", %{
      admin: admin,
      field: field
    } do
      assert error_message!(fn ->
               link!(admin, field, %{name: "quantity", label: "Again", field_type: :integer})
             end) =~ "taken"

      other = reference!(admin)
      assert link!(admin, other, %{name: "quantity", label: "Q", field_type: :integer})
    end

    test "only admins define link fields", %{field: field} do
      editor = user(:editor)

      assert_raise Ash.Error.Forbidden, fn ->
        link!(editor, field, %{name: "x", label: "X", field_type: :string})
      end
    end
  end

  describe "the write-time coercion" do
    test "link values are coerced onto the snapshot; defaults fill the rest",
         %{admin: admin, name: name} do
      flour = page!(admin, "Flour")
      salt = page!(admin, "Salt")

      post =
        post!(admin, %{
          name => [
            %{"id" => flour.id, "link" => %{"quantity" => "500"}},
            %{"id" => salt.id, "link" => %{"quantity" => "5", "role" => "garnish"}}
          ]
        })

      assert [
               %{"id" => flour_id, "title" => "Flour", "link" => flour_link},
               %{"id" => salt_id, "link" => salt_link}
             ] = post.custom_fields[name]

      assert {flour_id, salt_id} == {flour.id, salt.id}
      assert flour_link == %{"quantity" => 500, "role" => "main"}
      assert salt_link == %{"quantity" => 5, "role" => "garnish"}
    end

    test "invalid link values fail the field, naming the connection", %{admin: admin, name: name} do
      flour = page!(admin, "Flour")

      message =
        error_message!(fn ->
          post!(admin, %{name => [%{"id" => flour.id, "link" => %{"quantity" => "lots"}}]})
        end)

      assert message =~ "item 1 “Flour”: Quantity must be a whole number"

      message =
        error_message!(fn ->
          post!(admin, %{name => [%{"id" => flour.id, "link" => %{"role" => "side"}}]})
        end)

      assert message =~ "Role is not one of the allowed options"
    end

    test "required applies per connection", %{admin: admin, field: field, name: name} do
      link!(admin, field, %{name: "unit", label: "Unit", field_type: :string, required: true})
      flour = page!(admin, "Flour")

      assert error_message!(fn -> post!(admin, %{name => [flour.id]}) end) =~
               "“Flour”: Unit is required"

      post = post!(admin, %{name => [%{"id" => flour.id, "link" => %{"unit" => "g"}}]})
      assert [%{"link" => %{"unit" => "g"}}] = post.custom_fields[name]
    end

    test "an undeclared link key is refused", %{admin: admin, name: name} do
      flour = page!(admin, "Flour")

      assert error_message!(fn ->
               post!(admin, %{name => [%{"id" => flour.id, "link" => %{"colour" => "red"}}]})
             end) =~ ~s|"colour" is not a detail of this connection (details: quantity, role)|

      # Blank asks for nothing.
      post = post!(admin, %{name => [%{"id" => flour.id, "link" => %{"colour" => ""}}]})
      assert [%{"link" => %{"role" => "main"}}] = post.custom_fields[name]
    end

    test "an item that leaves link values out keeps what its connection stored",
         %{admin: admin, name: name} do
      flour = page!(admin, "Flour")
      salt = page!(admin, "Salt")

      post =
        post!(admin, %{
          name => [%{"id" => flour.id, "link" => %{"quantity" => 500, "role" => "garnish"}}]
        })

      # A bare id for a connection that already exists: kept as stored.
      {:ok, post} = update_post(post, %{name => [salt.id, flour.id]}, admin)

      assert links(post.custom_fields[name]) == [
               %{"role" => "main"},
               %{"quantity" => 500, "role" => "garnish"}
             ]

      # One key supplied: the other keeps its stored value.
      {:ok, post} =
        update_post(
          post,
          %{name => [salt.id, %{"id" => flour.id, "link" => %{"quantity" => 450}}]},
          admin
        )

      assert List.last(links(post.custom_fields[name])) == %{
               "quantity" => 450,
               "role" => "garnish"
             }

      # The stored list round-trips unchanged.
      {:ok, again} = update_post(post, post.custom_fields, admin)
      assert again.custom_fields[name] == post.custom_fields[name]
    end

    test "a single reference carries one link map", %{admin: admin} do
      field = reference!(admin, %{multiple: false})
      link!(admin, field, %{name: "note", label: "Note", field_type: :string})
      flour = page!(admin, "Flour")

      post = post!(admin, %{field.name => %{"id" => flour.id, "link" => %{"note" => " sifted "}}})
      assert %{"id" => _, "link" => %{"note" => "sifted"}} = post.custom_fields[field.name]
    end

    test "a reference without link fields stores the R1 shape exactly", %{admin: admin} do
      plain = reference!(admin)
      flour = page!(admin, "Flour")

      post = post!(admin, %{plain.name => [flour.id]})

      assert post.custom_fields[plain.name] == [
               %{"id" => flour.id, "type" => "page", "slug" => flour.slug, "title" => "Flour"}
             ]
    end

    test "a connection with no link value at all has no link key", %{admin: admin} do
      field = reference!(admin)
      link!(admin, field, %{name: "note", label: "Note", field_type: :string})
      flour = page!(admin, "Flour")

      post = post!(admin, %{field.name => [flour.id]})
      assert [snapshot] = post.custom_fields[field.name]
      refute Map.has_key?(snapshot, "link")
      assert edges(post, field.name) == [{flour.id, %{}}]
    end
  end

  describe "the edge copy" do
    test "each edge's metadata is its connection's link map, kept in step",
         %{admin: admin, name: name} do
      flour = page!(admin, "Flour")
      salt = page!(admin, "Salt")

      post =
        post!(admin, %{
          name => [
            %{"id" => flour.id, "link" => %{"quantity" => 500}},
            %{"id" => salt.id, "link" => %{"quantity" => 5}}
          ]
        })

      assert edges(post, name) == [
               {flour.id, %{"quantity" => 500, "role" => "main"}},
               {salt.id, %{"quantity" => 5, "role" => "main"}}
             ]

      # Changing only a link value rewrites that edge.
      {:ok, post} =
        update_post(
          post,
          %{name => [flour.id, %{"id" => salt.id, "link" => %{"role" => "garnish"}}]},
          admin
        )

      assert edges(post, name) == [
               {flour.id, %{"quantity" => 500, "role" => "main"}},
               {salt.id, %{"quantity" => 5, "role" => "garnish"}}
             ]
    end

    test "a curated link's metadata stays a free map", %{admin: admin} do
      a = page!(admin, "A")
      b = page!(admin, "B")

      link =
        CMS.create_content_link!(
          %{source_id: a.id, target_id: b.id, kind: :related, metadata: %{"anything" => [1, 2]}},
          actor: admin
        )

      assert link.metadata == %{"anything" => [1, 2]}
    end
  end

  describe "renaming and deleting a link field" do
    setup %{admin: admin, name: name} do
      flour = page!(admin, "Flour")
      salt = page!(admin, "Salt")

      list =
        post!(admin, %{
          name => [
            %{"id" => flour.id, "link" => %{"quantity" => 500}},
            %{"id" => salt.id, "link" => %{"quantity" => 5, "role" => "garnish"}}
          ]
        })

      single_field = reference!(admin, %{multiple: false})
      note = link!(admin, single_field, %{name: "note", label: "Note", field_type: :string})

      single =
        post!(admin, %{single_field.name => %{"id" => flour.id, "link" => %{"note" => "sifted"}}})

      %{list: list, single: single, single_field: single_field, note: note}
    end

    test "a rename moves the values in the snapshot and on the edges", ctx do
      CMS.update_field_definition!(ctx.quantity, %{name: "amount"}, actor: ctx.admin)

      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)

      assert links(list.custom_fields[ctx.name]) == [
               %{"amount" => 500, "role" => "main"},
               %{"amount" => 5, "role" => "garnish"}
             ]

      assert Enum.map(edges(list, ctx.name), &elem(&1, 1)) == links(list.custom_fields[ctx.name])

      CMS.update_field_definition!(ctx.note, %{name: "remark"}, actor: ctx.admin)
      single = CMS.get_post!(ctx.single.id, actor: ctx.admin)
      assert %{"link" => %{"remark" => "sifted"}} = single.custom_fields[ctx.single_field.name]
      assert [{_, %{"remark" => "sifted"}}] = edges(single, ctx.single_field.name)
    end

    test "a delete purges the values from both copies; an emptied link map goes", ctx do
      CMS.destroy_field_definition!(ctx.quantity, actor: ctx.admin)

      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)
      assert links(list.custom_fields[ctx.name]) == [%{"role" => "main"}, %{"role" => "garnish"}]
      assert Enum.map(edges(list, ctx.name), &elem(&1, 1)) == links(list.custom_fields[ctx.name])

      CMS.destroy_field_definition!(ctx.note, actor: ctx.admin)
      single = CMS.get_post!(ctx.single.id, actor: ctx.admin)
      refute Map.has_key?(single.custom_fields[ctx.single_field.name], "link")
      assert [{_, %{}}] = edges(single, ctx.single_field.name)

      # The record still saves: nothing undeclared is left behind.
      assert {:ok, _} = update_post(single, single.custom_fields, ctx.admin)
    end

    test "deleting the reference field deletes its link fields", ctx do
      CMS.destroy_field_definition!(ctx.field, actor: ctx.admin)

      assert {:error, _} = CMS.get_field_definition(ctx.quantity.id, actor: ctx.admin)
      assert {:error, _} = CMS.get_field_definition(ctx.role.id, actor: ctx.admin)
    end
  end

  describe "custom_filter on a link field" do
    setup %{admin: admin, name: name} do
      flour = page!(admin, "Flour", publish: true)
      salt = page!(admin, "Salt", publish: true)
      secret = page!(admin, "Secret")

      bread =
        post!(
          admin,
          %{
            name => [
              %{"id" => flour.id, "link" => %{"quantity" => 500}},
              %{"id" => salt.id, "link" => %{"quantity" => 5, "role" => "garnish"}}
            ]
          },
          publish: true
        )

      soup =
        post!(admin, %{name => [%{"id" => salt.id, "link" => %{"quantity" => 10}}]},
          publish: true
        )

      hidden =
        post!(
          admin,
          %{name => [%{"id" => secret.id, "link" => %{"quantity" => 1, "role" => "garnish"}}]},
          publish: true
        )

      %{bread: bread, soup: soup, hidden: hidden, scope: [bread, soup, hidden]}
    end

    defp matching(filter, actor, scope) do
      %{custom_filter: filter}
      |> CMS.list_posts!(actor: actor)
      |> Enum.map(& &1.id)
      |> Enum.filter(&(&1 in Enum.map(scope, fn post -> post.id end)))
      |> Enum.sort()
    end

    defp sorted(posts), do: posts |> Enum.map(& &1.id) |> Enum.sort()

    test "a record matches when some connection's value matches", ctx do
      m = &matching(%{"#{ctx.name}.link.#{&1}" => &2}, ctx.admin, ctx.scope)

      assert m.("role", "garnish") == sorted([ctx.bread, ctx.hidden])
      assert m.("role", %{"eq" => "main"}) == sorted([ctx.bread, ctx.soup])
      assert m.("quantity", %{"gte" => "10"}) == sorted([ctx.bread, ctx.soup])
      assert m.("quantity", %{"lt" => 5}) == [ctx.hidden.id]
      assert m.("quantity", %{"in" => ["5", "1"]}) == sorted([ctx.bread, ctx.hidden])
      assert m.("role", %{"ilike" => "garn%"}) == sorted([ctx.bread, ctx.hidden])

      # Two conditions on the same link field may be met by different
      # connections: each is its own `exists`.
      assert m.("quantity", %{"gt" => 400, "lt" => 6}) == [ctx.bread.id]
    end

    test "a draft target is invisible to an anonymous reader, visible to an editor", ctx do
      filter = %{"#{ctx.name}.link.role" => "garnish"}

      assert matching(filter, nil, ctx.scope) == [ctx.bread.id]
      assert matching(filter, user(:editor), ctx.scope) == sorted([ctx.bread, ctx.hidden])

      # The probe cannot learn the draft through its link data either.
      assert matching(%{"#{ctx.name}.link.quantity" => 1}, nil, ctx.scope) == []
    end

    test "bad names and operators are a 400, not a widened result", ctx do
      error = fn filter ->
        assert {:error, error} = CMS.list_posts(%{custom_filter: filter})
        Exception.message(error)
      end

      assert error.(%{"#{ctx.name}.link.colour" => "red"}) =~
               ~s|has no link field "colour" (link fields: quantity, role)|

      assert error.(%{"#{ctx.name}.link.role" => %{"has" => ["x"]}}) =~ "unknown operator"
      assert error.(%{"#{ctx.name}.link.quantity" => %{"gt" => "many"}}) =~ "invalid integer"
      assert error.(%{"nope.link.role" => "main"}) =~ ~s(unknown custom field "nope")
    end
  end

  describe "the schema export" do
    test "a reference reports its link fields on the snapshot's link object", ctx do
      schema = SchemaExport.json_schema()

      fields = fn type ->
        schema["$defs"][SchemaExport.content_def_name(type)]["properties"]["custom_fields"][
          "properties"
        ]
      end

      field = fields.(:post)[ctx.name]

      assert field["x-kiln-link-fields"] == ["quantity", "role"]
      assert %{"type" => "object", "properties" => link} = field["items"]["properties"]["link"]
      assert link["quantity"]["type"] == ["integer", "null"]
      # A choice's options stay unpublished, as on a top-level `:select`.
      assert link["role"] == %{"type" => ["string", "null"]}

      # A single reference with link fields spells out its snapshot.
      single = reference!(ctx.admin, %{multiple: false})
      link!(ctx.admin, single, %{name: "note", label: "Note", field_type: :string})

      single_schema =
        SchemaExport.json_schema()
        |> then(
          & &1["$defs"]["content_post"]["properties"]["custom_fields"]["properties"][single.name]
        )

      assert single_schema["required"] == ["id", "type"]
      assert single_schema["properties"]["link"]["properties"]["note"]

      ts = KilnCMS.SchemaExport.TypeScript.emit(schema)
      assert ts =~ "link?: { quantity?: number | null; role?: string | null }"
    end
  end
end
