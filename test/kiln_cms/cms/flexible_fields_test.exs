defmodule KilnCMS.CMS.FlexibleFieldsTest do
  @moduledoc """
  The `:flexible` custom field (#2282, `docs/flexible-content-plan.md`): a list
  of mixed typed items. Its item types are `:group` rows with `flex_of_id`, and
  their sub-fields ordinary `group_of_id` children. This covers the definition
  model and its write-time rules: the owner, the item-type and sub-field
  parents, the nesting cap, the options a flexible field refuses, and the
  readers that leave it out by type.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldKind
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.CMS.IndexedCustomFields
  alias KilnCMS.CMS.ListFields
  alias KilnCMS.CMS.PrivateFields
  alias KilnCMS.SchemaExport

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flex-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp flexible!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: unique("sections"),
          label: "Sections",
          field_type: :flexible
        },
        attrs
      ),
      actor: admin
    )
  end

  defp item_type!(admin, flexible, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{name: unique("hero"), label: "Hero", field_type: :group, flex_of_id: flexible.id},
        attrs
      ),
      actor: admin
    )
  end

  defp sub!(admin, parent, attrs),
    do:
      CMS.create_field_definition!(
        Map.merge(%{label: "Sub", field_type: :string}, Map.put(attrs, :group_of_id, parent.id)),
        actor: admin
      )

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  defp loaded(admin, flexible) do
    :post
    |> CMS.field_definitions_for!(actor: admin)
    |> Enum.find(&(&1.id == flexible.id))
  end

  setup do
    admin = user(:admin)
    flexible = flexible!(admin)
    hero = item_type!(admin, flexible, %{name: "hero", position: 0})
    quote_type = item_type!(admin, flexible, %{name: "quote", label: "Quote", position: 1})

    headline = sub!(admin, hero, %{name: "headline", label: "Headline"})
    background = sub!(admin, hero, %{name: "background", item_setting: true, position: 1})

    %{
      admin: admin,
      flexible: flexible,
      hero: hero,
      quote_type: quote_type,
      headline: headline,
      background: background
    }
  end

  describe "the registry" do
    test "flexible is a reserved core type and a known field type" do
      assert :flexible in FieldTypes.core()
      assert :flexible in FieldTypes.reserved()
      assert :flexible in FieldDefinition.field_types()
      refute FieldDefinition.unknown_type?(%{field_type: :flexible})
      assert FieldTypes.get(:flexible) == nil
    end

    test "FieldKind serves a flexible field as a list of flexible items", %{
      flexible: flexible
    } do
      assert FieldKind.item_kind_for(%{field_type: :flexible, multiple: true}) == :flexible_item
      assert FieldKind.kind_for(flexible) == :list
    end

    test "the nesting cap is three levels, and a flexible field may sit in an item type" do
      assert FieldDefinition.max_flexible_depth() == 3
      assert :flexible in FieldDefinition.item_field_types()
      assert FieldDefinition.link_field_types() -- FieldDefinition.item_field_types() == []
      refute :flexible in FieldDefinition.link_field_types()
    end

    test "top_level?/1 and parent_id/1 know all three parent columns" do
      assert FieldDefinition.top_level?(%{link_of_id: nil, group_of_id: nil, flex_of_id: nil})
      refute FieldDefinition.top_level?(%{link_of_id: "a"})
      refute FieldDefinition.top_level?(%{group_of_id: "a"})
      refute FieldDefinition.top_level?(%{flex_of_id: "a"})

      assert FieldDefinition.parent_id(%{flex_of_id: "f"}) == "f"
      assert FieldDefinition.parent_id(%{group_of_id: "g", flex_of_id: nil}) == "g"
      assert FieldDefinition.item_type?(%{flex_of_id: "f"})
      refute FieldDefinition.item_type?(%{flex_of_id: nil})
    end
  end

  describe "the definition" do
    test "a flexible field is always a list, whatever it was created with", %{admin: admin} do
      field = flexible!(admin, %{multiple: false, min_items: 1, max_items: 4})
      assert field.multiple
      assert {field.min_items, field.max_items} == {1, 4}

      updated = CMS.update_field_definition!(field, %{multiple: false}, actor: admin)
      assert updated.multiple
    end

    test "an item type keeps its per-type bounds", %{admin: admin, flexible: flexible} do
      item = item_type!(admin, flexible, %{max_items: 3, min_items: 1})
      assert item.multiple
      assert {item.min_items, item.max_items} == {1, 3}
      assert item.content_type == nil
      assert item.type_definition_id == nil
    end

    test "item types load with their sub-fields, in order, and are not fields of the type",
         %{admin: admin, flexible: flexible, hero: hero, quote_type: quote_type} do
      definitions = CMS.field_definitions_for!(:post, actor: admin)

      refute Enum.any?(definitions, &(&1.flex_of_id == flexible.id))
      refute Enum.any?(definitions, &(&1.id in [hero.id, quote_type.id]))

      parent = Enum.find(definitions, &(&1.id == flexible.id))
      types = FieldDefinition.item_types(parent)

      assert Enum.map(types, & &1.name) == ["hero", "quote"]

      assert [hero_loaded, quote_loaded] = types

      assert hero_loaded
             |> FieldDefinition.group_fields()
             |> Enum.map(&{&1.name, &1.item_setting}) ==
               [{"headline", false}, {"background", true}]

      assert FieldDefinition.group_fields(quote_loaded) == []
    end

    test "item_types raises when not loaded and is [] for any other type", %{flexible: flexible} do
      unloaded = %{flexible | item_types: %Ash.NotLoaded{}}

      assert_raise ArgumentError, ~r/item_types not loaded/, fn ->
        FieldDefinition.item_types(unloaded)
      end

      assert FieldDefinition.item_types(%{field_type: :group}) == []
    end

    test "a type's own read does not list item types or their sub-fields", %{admin: admin} do
      listed =
        for %{content_type: :post} = definition <- CMS.field_definitions_for!(:post, actor: admin),
            do: definition.name

      refute "hero" in listed
      refute "headline" in listed
    end

    test "for_definition loads item types of a dynamic type too", %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: unique("dyn"), label: "Dyn"},
          actor: admin
        )

      field =
        flexible!(admin, %{content_type: nil, type_definition_id: type.id, name: "blocks"})

      item_type!(admin, field, %{name: "card"})

      assert [loaded] = CMS.field_definitions_for_definition!(type.id, actor: admin)
      assert loaded |> FieldDefinition.item_types() |> Enum.map(& &1.name) == ["card"]
    end

    test "item_setting defaults to false", %{headline: headline, background: background} do
      refute headline.item_setting
      assert background.item_setting
    end

    test "an item type name is unique within its flexible field", ctx do
      %{admin: admin, flexible: flexible} = ctx

      assert {:error, _} =
               dup = CMS.create_field_definition(item_attrs(flexible, "hero"), actor: admin)

      assert Exception.message(elem(dup, 1)) =~ "has already been taken"

      other = flexible!(admin)
      assert %{name: "hero"} = item_type!(admin, other, %{name: "hero"})
    end

    test "destroying the flexible field takes its item types and their sub-fields",
         %{admin: admin, flexible: flexible, hero: hero, headline: headline} do
      CMS.destroy_field_definition!(flexible, actor: admin)

      for id <- [flexible.id, hero.id, headline.id] do
        assert {:error, _} = CMS.get_field_definition(id, actor: admin)
      end
    end

    test "the schema export types a flexible field as an array of its item union and skips item types",
         %{admin: admin, flexible: flexible} do
      CMS.update_field_definition!(flexible, %{max_items: 8}, actor: admin)

      document = SchemaExport.json_schema()

      properties =
        document["$defs"][SchemaExport.content_def_name(:post)]["properties"]["custom_fields"][
          "properties"
        ]

      assert %{
               "type" => ["array", "null"],
               "items" => %{"$ref" => "#/$defs/" <> union},
               "x-kiln-max-items" => 8
             } = properties[flexible.name]

      assert %{"oneOf" => [%{"$ref" => _}, %{"$ref" => _}], "x-kiln-flexible" => annotation} =
               document["$defs"][union]

      assert %{"content_type" => "post", "field" => field, "path" => [field]} = annotation
      assert field == flexible.name

      refute Map.has_key?(properties, "hero")
      refute Map.has_key?(properties, "headline")
    end
  end

  defp item_attrs(flexible, name),
    do: %{name: name, label: "Item", field_type: :group, flex_of_id: flexible.id}

  describe "the owner" do
    test "an item type has the flexible field as its only owner", %{admin: admin, flexible: f} do
      assert error_message!(fn ->
               item_type!(admin, f, %{content_type: :post})
             end) =~ "an item type belongs to its flexible field, not directly to a content type"

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{
                   name: "x",
                   label: "X",
                   field_type: :group,
                   flex_of_id: f.id,
                   group_of_id: f.id
                 },
                 actor: admin
               )
             end) =~ "more than one of a reference, a group and a flexible field"

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{name: "x", label: "X", field_type: :group, flex_of_id: f.id, link_of_id: f.id},
                 actor: admin
               )
             end) =~ "more than one of a reference, a group and a flexible field"
    end

    test "the existing link-and-group conflict keeps its message", %{admin: admin, flexible: f} do
      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{name: "x", label: "X", link_of_id: f.id, group_of_id: f.id},
                 actor: admin
               )
             end) =~ "a field cannot be both a link field and a group's sub-field"
    end

    test "a field with no owner is still refused", %{admin: admin} do
      assert error_message!(fn ->
               CMS.create_field_definition!(%{name: "x", label: "X"}, actor: admin)
             end) =~ "a field must belong to a content type or a type definition"
    end
  end

  describe "item types" do
    test "the parent must be a flexible field", %{admin: admin} do
      text =
        CMS.create_field_definition!(%{content_type: :post, name: "ff_note", label: "N"},
          actor: admin
        )

      assert error_message!(fn -> item_type!(admin, text) end) =~
               "item types can only be added to a flexible field"

      group =
        CMS.create_field_definition!(
          %{content_type: :post, name: "grp", label: "G", field_type: :group},
          actor: admin
        )

      assert error_message!(fn -> item_type!(admin, group) end) =~
               "item types can only be added to a flexible field"
    end

    test "the parent must be a field of this site", %{admin: admin} do
      assert error_message!(fn -> item_type!(admin, %{id: Ash.UUID.generate()}) end) =~
               "is not a field of this site"
    end

    test "an item type is a group", %{admin: admin, flexible: flexible} do
      assert error_message!(fn -> item_type!(admin, flexible, %{field_type: :string}) end) =~
               "an item type must be a group"

      assert error_message!(fn -> item_type!(admin, flexible, %{field_type: :flexible}) end) =~
               "an item type must be a group"
    end

    test "an item type stays in its flexible field", %{admin: admin, hero: hero} do
      other = flexible!(admin)

      assert error_message!(fn ->
               CMS.update_field_definition!(hero, %{flex_of_id: other.id}, actor: admin)
             end) =~ "an item type stays in the flexible field it was added to"
    end

    test "an item type carries no record-level options", %{admin: admin, flexible: flexible} do
      item = item_type!(admin, flexible, %{section: "Body", width: :half, searchable: true})

      assert item.section == nil
      assert item.width == :full
      refute item.searchable
    end

    test "a non-admin cannot define one", %{flexible: flexible} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_definition(item_attrs(flexible, "sneaky"), actor: user(:editor))
    end
  end

  describe "sub-fields of an item type" do
    test "take the plain types", %{admin: admin, hero: hero} do
      for {type, extra} <- [
            string: %{},
            text: %{},
            integer: %{},
            float: %{},
            boolean: %{},
            date: %{},
            datetime: %{},
            url: %{},
            select: %{options: ["a", "b"]}
          ] do
        assert %{field_type: ^type} =
                 sub!(admin, hero, Map.merge(%{name: unique("f"), field_type: type}, extra))
      end
    end

    test "refuse a group and a computed field", %{admin: admin, hero: hero} do
      for type <- [:group, :computed] do
        assert error_message!(fn ->
                 sub!(admin, hero, %{name: unique("f"), field_type: type})
               end) =~ "can't be used inside an item type"
      end
    end

    test "take a media snapshot and a reference (#2282, PR 3), one value each", %{
      admin: admin,
      hero: hero
    } do
      assert %{field_type: :media, multiple: false} =
               sub!(admin, hero, %{name: unique("m"), field_type: :media, multiple: true})

      assert %{field_type: :reference, multiple: false} =
               sub!(admin, hero, %{
                 name: unique("r"),
                 field_type: :reference,
                 target_type: "page",
                 multiple: true
               })
    end

    test "are not allowed to be a setting when nested flexible, or outside an item type", ctx do
      %{admin: admin, hero: hero} = ctx

      assert error_message!(fn ->
               sub!(admin, hero, %{name: "nested", field_type: :flexible, item_setting: true})
             end) =~ "a setting can't be a flexible field"

      group =
        CMS.create_field_definition!(
          %{content_type: :post, name: unique("grp"), label: "G", field_type: :group},
          actor: admin
        )

      assert error_message!(fn ->
               sub!(admin, group, %{name: "x", item_setting: true})
             end) =~ "only a sub-field of an item type can be a setting"

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{content_type: :post, name: "top", label: "T", item_setting: true},
                 actor: admin
               )
             end) =~ "only a sub-field of an item type can be a setting"

      assert error_message!(fn ->
               item_type!(admin, ctx.flexible, %{item_setting: true})
             end) =~ "only a sub-field of an item type can be a setting"
    end

    test "cannot change item_setting once they exist", ctx do
      %{admin: admin, headline: headline, background: background} = ctx

      for {sub, flipped} <- [{headline, true}, {background, false}] do
        assert error_message!(fn ->
                 CMS.update_field_definition!(sub, %{item_setting: flipped}, actor: admin)
               end) =~ "can't change once the sub-field exists"
      end
    end

    test "carry no record-level options and cannot be unique", %{admin: admin, hero: hero} do
      sub = sub!(admin, hero, %{name: "tagline", searchable: true, names_record: true})
      refute sub.searchable
      refute sub.names_record

      assert error_message!(fn ->
               sub!(admin, hero, %{name: "slugish", validation: %{"unique" => true}})
             end) =~ "unique can't be set on a field inside a relationship or group"

      assert error_message!(fn ->
               sub!(admin, hero, %{name: "secretive", private: true})
             end) =~ "only for a top-level field"
    end

    test "may be governed by a sibling inside the same item type", ctx do
      %{admin: admin, hero: hero} = ctx

      sub =
        sub!(admin, hero, %{
          name: "caption",
          visible_when: %{"field" => "headline", "op" => "eq", "value" => "x"}
        })

      assert sub.visible_when
    end

    test "a plain group does not take a flexible sub-field", %{admin: admin} do
      group =
        CMS.create_field_definition!(
          %{content_type: :post, name: unique("grp"), label: "G", field_type: :group},
          actor: admin
        )

      assert error_message!(fn ->
               sub!(admin, group, %{name: "inner", field_type: :flexible})
             end) =~ "a flexible field can only be added to an item type"
    end

    test "a link field does not take a flexible type either", %{admin: admin} do
      reference =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: unique("ref"),
            label: "R",
            field_type: :reference,
            target_type: "post"
          },
          actor: admin
        )

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{name: "x", label: "X", field_type: :flexible, link_of_id: reference.id},
                 actor: admin
               )
             end) =~ "can't be used for details on a connection"
    end

    test "an item type's sub-field cannot itself have sub-fields", %{
      admin: admin,
      headline: headline
    } do
      assert error_message!(fn -> sub!(admin, headline, %{name: "deeper"}) end) =~
               "sub-fields can only be added to a group field"
    end
  end

  describe "nesting" do
    # level 1 is `flexible`; each call adds a flexible sub-field to an item type
    defp nest!(admin, flexible) do
      item = item_type!(admin, flexible, %{name: unique("item")})
      {item, sub!(admin, item, %{name: unique("inner"), field_type: :flexible})}
    end

    test "a flexible field nests down to the cap and loads the whole tree", %{
      admin: admin,
      flexible: l1
    } do
      {_item1, l2} = nest!(admin, l1)
      {_item2, l3} = nest!(admin, l2)
      leaf_type = item_type!(admin, l3, %{name: "leaf"})
      leaf = sub!(admin, leaf_type, %{name: "value"})

      loaded = loaded(admin, l1)

      assert [with_nested | _] =
               loaded |> FieldDefinition.item_types() |> Enum.filter(&(&1.name != "hero"))

      assert [l2_loaded] = FieldDefinition.group_fields(with_nested)
      assert l2_loaded.id == l2.id
      assert [item2] = FieldDefinition.item_types(l2_loaded)
      assert [l3_loaded] = FieldDefinition.group_fields(item2)
      assert l3_loaded.id == l3.id
      assert [leaf_loaded] = FieldDefinition.item_types(l3_loaded)
      assert [value] = FieldDefinition.group_fields(leaf_loaded)
      assert value.id == leaf.id
    end

    test "a fourth level is refused where the flexible sub-field is added", %{
      admin: admin,
      flexible: l1
    } do
      {_item1, l2} = nest!(admin, l1)
      {item2, l3} = nest!(admin, l2)
      assert l3.field_type == :flexible
      assert l3.group_of_id == item2.id

      l3_item = item_type!(admin, l3, %{name: "leaf"})

      assert error_message!(fn ->
               sub!(admin, l3_item, %{name: "too_deep", field_type: :flexible})
             end) =~ "flexible fields nest at most 3 levels deep"
    end

    test "the second and third levels are accepted, the first has no sub-field to refuse", %{
      admin: admin,
      flexible: l1
    } do
      {_item1, l2} = nest!(admin, l1)
      assert FieldDefinition.max_flexible_depth() >= 3

      assert KilnCMS.CMS.Validations.FlexibleField.depth(l1, nil) == 1
      assert KilnCMS.CMS.Validations.FlexibleField.depth(l2, nil) == 2
    end
  end

  describe "options a flexible field refuses" do
    test "names_record, private, default, setting", %{admin: admin} do
      for {attrs, message} <- [
            {%{names_record: true}, "can't be a name of the record"},
            {%{private: true}, "can't be private"},
            {%{default: "x"}, "takes no default value"},
            {%{item_setting: true}, "can't be a setting"}
          ] do
        assert error_message!(fn -> flexible!(admin, attrs) end) =~ message
      end
    end

    test "a formula is dropped: a flexible field is never computed", %{admin: admin} do
      assert flexible!(admin, %{compute: "{{ title }}"}).compute == nil
    end

    test "unique and value constraints", %{admin: admin} do
      assert error_message!(fn -> flexible!(admin, %{validation: %{"unique" => true}}) end) =~
               "can't be set on a flexible field"
    end

    test "its own conditions", %{admin: admin} do
      rule = %{"field" => "other", "op" => "eq", "value" => "x"}

      assert error_message!(fn -> flexible!(admin, %{visible_when: rule}) end) =~
               "is not available for a flexible field"

      assert error_message!(fn -> flexible!(admin, %{required_when: rule}) end) =~
               "is not available for a flexible field"
    end

    test "a flexible field can be searchable (#2282 PR 6)", %{admin: admin, flexible: flexible} do
      assert flexible!(admin, %{searchable: true}).searchable
      assert CMS.update_field_definition!(flexible, %{searchable: true}, actor: admin).searchable
    end

    test "a flexible field cannot be retyped to private after the fact", %{admin: admin} do
      field =
        CMS.create_field_definition!(
          %{content_type: :post, name: unique("p"), label: "P", private: true},
          actor: admin
        )

      assert error_message!(fn ->
               CMS.update_field_definition!(field, %{field_type: :flexible}, actor: admin)
             end) =~ "can't be private"
    end
  end

  describe "editing definitions leaves unrelated top-level keys alone" do
    # An item type's or sub-field's values live inside the items of its flexible
    # field (`FlexiblePath`), so a rename or a delete there must not touch a
    # top-level key of the same name.
    test "renaming or deleting an item type or its sub-field purges no top-level key",
         %{admin: admin, hero: hero, headline: headline} = ctx do
      post =
        CMS.create_post!(%{title: "T", slug: "p-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      # A write refuses keys no definition declares, so seed the stored data.
      KilnCMS.Repo.query!("UPDATE posts SET custom_fields = $1::jsonb WHERE id = $2", [
        %{"hero" => "keep", "headline" => "keep"},
        Ecto.UUID.dump!(post.id)
      ])

      ExUnit.CaptureLog.capture_log(fn ->
        CMS.update_field_definition!(ctx.background, %{name: "bg"}, actor: admin)
        CMS.update_field_definition!(headline, %{name: "title_text"}, actor: admin)
        CMS.update_field_definition!(hero, %{name: "banner"}, actor: admin)
        CMS.destroy_field_definition!(hero, actor: admin)
      end)

      assert %{rows: [[%{"hero" => "keep", "headline" => "keep"}]]} =
               KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [
                 Ecto.UUID.dump!(post.id)
               ])
    end
  end

  describe "the readers that exclude by type" do
    test "private fields, list columns and index targets leave it out", %{flexible: flexible} do
      refute :flexible in PrivateFields.types()
      refute :flexible in ListFields.picker_types()
      refute ListFields.pickable?(flexible)
      refute :flexible in IndexedCustomFields.eligible_types()
    end

    test "custom_filter answers null and nothing else, and it cannot be a sort key",
         %{admin: admin, flexible: flexible} do
      name = flexible.name

      assert {:ok, _} =
               CMS.list_posts(%{custom_filter: %{name => %{"null" => true}}}, actor: admin)

      assert {:error, error} =
               CMS.list_posts(%{custom_filter: %{name => %{"eq" => "x"}}}, actor: admin)

      assert Exception.message(error) =~ "(flexible) only supports null"

      assert {:error, error} = CMS.list_posts(%{custom_sort: name}, actor: admin)
      assert Exception.message(error) =~ "(flexible) is not sortable"
    end
  end
end
