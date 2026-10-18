defmodule KilnCMS.CMS.ReverseFieldsTest do
  @moduledoc """
  Workstream R4 of `docs/relationships-plan.md`: **reverse fields** — the
  other side of a `:reference` field (`inverse_label` / `inverse_name`), as
  its targets see it. Covers the definition rules, which types show which
  reverse fields, the rows (ordered, paginated, with link data, under the
  both-ends read rule) and the schema export.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ReverseFields
  alias KilnCMS.SchemaExport

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "reverse-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "reverse-#{uniq()}"

  defp reference!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "ingredients_#{uniq()}",
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

  defp field_error(attrs, admin) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             CMS.create_field_definition(
               Map.merge(
                 %{
                   content_type: :post,
                   name: "f_#{uniq()}",
                   label: "F",
                   field_type: :reference,
                   target_type: "page"
                 },
                 attrs
               ),
               actor: admin
             )

    errors
  end

  defp page!(admin, title, opts \\ []) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if opts[:publish], do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp post!(admin, title, fields, opts \\ []) do
    post = CMS.create_post!(%{title: title, slug: slug(), custom_fields: fields}, actor: admin)
    if opts[:publish], do: CMS.publish_post!(post, %{}, actor: admin), else: post
  end

  setup do
    %{admin: user(:admin)}
  end

  describe "the definition" do
    test "a label suggests the machine name", %{admin: admin} do
      field = reference!(admin, %{inverse_label: "Recipes using this ingredient"})
      assert field.inverse_name == "recipes_using_this_ingredient"
    end

    test "a machine name that is given is kept", %{admin: admin} do
      field = reference!(admin, %{inverse_label: "Used in", inverse_name: "used_in"})
      assert {field.inverse_label, field.inverse_name} == {"Used in", "used_in"}
    end

    test "only a top-level reference has another side", %{admin: admin} do
      text =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "t_#{uniq()}",
            label: "T",
            field_type: :string,
            inverse_label: "Nope"
          },
          actor: admin
        )

      assert {text.inverse_label, text.inverse_name} == {nil, nil}

      parent = reference!(admin, %{})

      link =
        CMS.create_field_definition!(
          %{link_of_id: parent.id, name: "role", label: "Role", field_type: :string},
          actor: admin
        )

      assert {:ok, link} =
               CMS.update_field_definition(link, %{inverse_label: "Nope"}, actor: admin)

      assert link.inverse_label == nil
    end

    test "the machine name is a safe identifier", %{admin: admin} do
      errors = field_error(%{inverse_label: "X", inverse_name: "Bad Name"}, admin)
      assert Enum.any?(errors, &(&1.field == :inverse_name))
    end

    test "a machine name needs a label", %{admin: admin} do
      errors = field_error(%{inverse_name: "used_in"}, admin)
      assert Enum.any?(errors, &(&1.field == :inverse_label))
    end

    test "is unique among the reverse fields of a target type", %{admin: admin} do
      reference!(admin, %{inverse_label: "Used in", inverse_name: "used_in"})

      errors = field_error(%{inverse_label: "Also used in", inverse_name: "used_in"}, admin)
      assert Enum.any?(errors, &(&1.field == :inverse_name and &1.message =~ "already used"))

      # Another target type may reuse the name: it is a different type's field.
      assert {:ok, _field} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "f_#{uniq()}",
                   label: "F",
                   field_type: :reference,
                   target_type: "post",
                   inverse_label: "Used in",
                   inverse_name: "used_in"
                 },
                 actor: admin
               )
    end

    test "a field keeps its own name when it is saved again", %{admin: admin} do
      field = reference!(admin, %{inverse_label: "Used in", inverse_name: "used_in"})
      assert {:ok, _field} = CMS.update_field_definition(field, %{label: "Renamed"}, actor: admin)
    end
  end

  describe "for_type/2" do
    test "lists the reverse fields of every reference that may point at the type", %{admin: admin} do
      plain = reference!(admin, %{inverse_label: "Posts using this"})

      many =
        reference!(admin, %{
          target_type: nil,
          target_types: ["post", "page"],
          inverse_label: "Mentioned by"
        })

      _none = reference!(admin, %{})

      reverse = ReverseFields.for_type(:page, nil)
      assert Enum.map(reverse, & &1.field) |> Enum.sort() == Enum.sort([plain.name, many.name])

      assert %{label: "Posts using this", source_type: "post", source_label: "Post"} =
               Enum.find(reverse, &(&1.field == plain.name))

      assert [%{field: field}] = ReverseFields.for_type("post", nil)
      assert field == many.name
    end
  end

  describe "rows/3" do
    setup %{admin: admin} do
      field = reference!(admin, %{inverse_label: "Used in"})

      CMS.create_field_definition!(
        %{link_of_id: field.id, name: "quantity", label: "Quantity", field_type: :integer},
        actor: admin
      )

      [reverse] = ReverseFields.for_type(:page, nil)
      target = page!(admin, "Flour", publish: true)

      item = fn qty -> [%{"id" => target.id, "link" => %{"quantity" => qty}}] end

      live =
        for title <- ["Cake", "Bread", "Apple pie"],
            do: post!(admin, title, %{field.name => item.(2)}, publish: true)

      draft = post!(admin, "Draft scones", %{field.name => item.(3)})

      %{reverse: reverse, target: target, live: live, draft: draft}
    end

    test "lists the sources by title, with each connection's link data", ctx do
      %{rows: rows, total: 4} = ReverseFields.rows(ctx.target, ctx.reverse, actor: ctx.admin)

      assert Enum.map(rows, & &1.source.title) == ["Apple pie", "Bread", "Cake", "Draft scones"]
      assert Enum.map(rows, & &1.link.metadata["quantity"]) == [2, 2, 2, 3]
    end

    test "pages through them", ctx do
      opts = [actor: ctx.admin, limit: 3]

      assert %{rows: first, total: 4} = ReverseFields.rows(ctx.target, ctx.reverse, opts)
      assert length(first) == 3

      assert %{rows: [last], total: 4} =
               ReverseFields.rows(ctx.target, ctx.reverse, [offset: 3] ++ opts)

      assert last.source.title == "Draft scones"
    end

    test "a reader who may not read a draft source is not shown it, nor counts it", ctx do
      %{rows: rows, total: 3} = ReverseFields.rows(ctx.target, ctx.reverse, actor: nil)
      refute Enum.any?(rows, &(&1.source.id == ctx.draft.id))
    end

    test "a record nothing connects to has no rows", ctx do
      other = page!(ctx.admin, "Sugar")
      assert %{rows: [], total: 0} = ReverseFields.rows(other, ctx.reverse, actor: ctx.admin)
    end
  end

  describe "the schema export" do
    test "names the other side on the reference and on its target type", %{admin: admin} do
      field = reference!(admin, %{inverse_label: "Used in", inverse_name: "used_in"})

      schema = SchemaExport.json_schema()
      post = schema["$defs"][SchemaExport.content_def_name(:post)]
      page = schema["$defs"][SchemaExport.content_def_name(:page)]

      assert post["properties"]["custom_fields"]["properties"][field.name]["x-kiln-inverse"] ==
               %{"name" => "used_in", "label" => "Used in"}

      assert page["x-kiln-reverse-fields"] == [
               %{
                 "name" => "used_in",
                 "label" => "Used in",
                 "field" => field.name,
                 "source_type" => "post"
               }
             ]

      refute Map.has_key?(post, "x-kiln-reverse-fields")
    end
  end
end
