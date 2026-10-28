defmodule KilnCMS.CMS.GroupFieldsTest do
  @moduledoc """
  The `:group` custom field: structured rows whose keys are `FieldDefinition`
  rows with `group_of_id` (sub-fields). Covers the definition rules, the
  write-time coercion of one object and of a list of them (with error paths),
  renaming and deleting a sub-field or flipping `multiple` over stored rows,
  the filter/sort refusals, and the schema export and `.d.ts` it feeds.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.SchemaExport

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "group-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "group-#{System.unique_integer([:positive])}"

  defp group!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "dosages_#{System.unique_integer([:positive])}",
          label: "Dosages",
          field_type: :group,
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp sub!(admin, group, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :group_of_id, group.id), actor: admin)

  defp post!(admin, fields),
    do: CMS.create_post!(%{title: "Herb", slug: slug(), custom_fields: fields}, actor: admin)

  defp update_post(post, fields, admin),
    do: CMS.update_post(post, %{custom_fields: fields}, actor: admin)

  defp error_message!(fun) do
    error = assert_raise(Ash.Error.Invalid, fun)
    Exception.message(error)
  end

  setup do
    admin = user(:admin)
    group = group!(admin)

    amount = sub!(admin, group, %{name: "amount", label: "Amount", field_type: :float})

    unit =
      sub!(admin, group, %{
        name: "unit",
        label: "Unit",
        field_type: :select,
        options: ["g", "ml"],
        required: true,
        position: 1
      })

    form =
      sub!(admin, group, %{
        name: "form",
        label: "Form",
        field_type: :string,
        default: "dried",
        position: 2
      })

    %{admin: admin, group: group, name: group.name, amount: amount, unit: unit, form: form}
  end

  describe "the definition" do
    test "sub-fields load with their group, in order, and are not fields of the type",
         %{admin: admin, group: group} do
      definitions = CMS.field_definitions_for!(:post, actor: admin)

      refute Enum.any?(definitions, &(&1.group_of_id == group.id))

      parent = Enum.find(definitions, &(&1.id == group.id))

      assert parent |> FieldDefinition.group_fields() |> Enum.map(& &1.name) ==
               ~w(amount unit form)

      assert FieldDefinition.link_fields(parent) == []
    end

    test "group_fields raises when not loaded, and is [] for any other type", %{group: group} do
      unloaded = %{group | group_fields: %Ash.NotLoaded{}}

      assert_raise ArgumentError, ~r/group_fields not loaded/, fn ->
        FieldDefinition.group_fields(unloaded)
      end

      assert FieldDefinition.group_fields(%{field_type: :string}) == []
    end

    test "a sub-field belongs to a top-level group only", %{admin: admin, unit: unit} do
      text =
        CMS.create_field_definition!(
          %{content_type: :post, name: "note_#{System.unique_integer([:positive])}", label: "N"},
          actor: admin
        )

      assert error_message!(fn ->
               sub!(admin, text, %{name: "x", label: "X", field_type: :string})
             end) =~ "sub-fields can only be added to a group field"

      assert error_message!(fn ->
               sub!(admin, unit, %{name: "x", label: "X", field_type: :string})
             end) =~ "sub-fields can only be added to a group field"
    end

    test "exactly one owner", %{admin: admin, group: group} do
      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{content_type: :post, group_of_id: group.id, name: "x", label: "X"},
                 actor: admin
               )
             end) =~ "a sub-field belongs to its group"

      reference =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "ref_#{System.unique_integer([:positive])}",
            label: "Ref",
            field_type: :reference,
            target_type: "page"
          },
          actor: admin
        )

      assert error_message!(fn ->
               CMS.create_field_definition!(
                 %{link_of_id: reference.id, group_of_id: group.id, name: "x", label: "X"},
                 actor: admin
               )
             end) =~ "cannot be both a link field and a group's sub-field"
    end

    test "only the plain types — no nesting; record-level options are cleared",
         %{admin: admin, group: group} do
      for type <- [:group, :reference, :media, :computed, :geolocation] do
        assert error_message!(fn ->
                 sub!(admin, group, %{name: "x_#{type}", label: "X", field_type: type})
               end) =~ "can't be used inside a group"
      end

      sub =
        sub!(admin, group, %{
          name: "note",
          label: "Note",
          field_type: :string,
          searchable: true,
          names_record: true,
          localization: :shared
        })

      assert %{searchable: false, names_record: false, localization: :localized} = sub
    end

    test "a sub-field stays in its group", %{admin: admin, unit: unit} do
      other = group!(admin)

      assert error_message!(fn ->
               CMS.update_field_definition!(unit, %{group_of_id: other.id}, actor: admin)
             end) =~ "stays in the group"
    end

    test "sub-field names are unique per group, not across them", %{admin: admin, group: group} do
      assert error_message!(fn ->
               sub!(admin, group, %{name: "unit", label: "Again", field_type: :string})
             end) =~ "taken"

      assert sub!(admin, group!(admin), %{name: "unit", label: "Unit", field_type: :string})
    end

    test "a group keeps multiple and its bounds; a scalar loses them", %{admin: admin} do
      assert %{multiple: true, min_items: 1, max_items: 3} =
               group!(admin, %{min_items: 1, max_items: 3})

      assert %{multiple: false, min_items: nil} =
               CMS.create_field_definition!(
                 %{
                   content_type: :post,
                   name: "s_#{System.unique_integer([:positive])}",
                   label: "S",
                   field_type: :integer,
                   multiple: true,
                   min_items: 1
                 },
                 actor: admin
               )
    end

    test "only admins define sub-fields", %{group: group} do
      assert_raise Ash.Error.Forbidden, fn ->
        sub!(user(:editor), group, %{name: "x", label: "X", field_type: :string})
      end
    end

    test "deleting the group deletes its sub-fields", %{admin: admin} = ctx do
      CMS.destroy_field_definition!(ctx.group, actor: admin)

      for sub <- [ctx.amount, ctx.unit, ctx.form],
          do: assert({:error, _} = CMS.get_field_definition(sub.id, actor: admin))
    end
  end

  describe "the write-time coercion" do
    test "a list of rows is coerced per sub-field; defaults fill the rest",
         %{admin: admin, name: name} do
      post =
        post!(admin, %{
          name => [
            %{"amount" => "1.5", "unit" => " g "},
            %{amount: 10, unit: "ml", form: "tincture"}
          ]
        })

      assert post.custom_fields[name] == [
               %{"amount" => 1.5, "unit" => "g", "form" => "dried"},
               %{"amount" => 10.0, "unit" => "ml", "form" => "tincture"}
             ]
    end

    test "a lone object is a one-row list; blank rows are no rows", %{admin: admin, name: name} do
      post = post!(admin, %{name => %{"unit" => "g"}})
      assert post.custom_fields[name] == [%{"unit" => "g", "form" => "dried"}]

      {:ok, post} =
        update_post(
          post,
          %{name => [%{"unit" => "", "amount" => ""}, %{}, nil, %{"unit" => "ml"}]},
          admin
        )

      assert post.custom_fields[name] == [%{"unit" => "ml", "form" => "dried"}]

      {:ok, post} = update_post(post, %{name => []}, admin)
      refute Map.has_key?(post.custom_fields, name)
    end

    test "every problem is reported under its path", %{admin: admin, name: name} do
      message =
        error_message!(fn ->
          post!(admin, %{
            name => [
              %{"unit" => "g"},
              %{"amount" => "lots", "unit" => "kg"},
              %{"amount" => 1, "colour" => "red"},
              "prose in a dosages field"
            ]
          })
        end)

      assert message =~ "Amount (#{name}[1].amount) must be a number"
      assert message =~ "Unit (#{name}[1].unit) is not one of the allowed options"
      assert message =~ "Unit (#{name}[2].unit) is required"

      assert message =~
               "Dosages (#{name}[2].colour) is not a sub-field of this group (sub-fields: amount, form, unit)"

      assert message =~ "Dosages (#{name}[3]) must be an object"
    end

    test "a nested value in a row is refused", %{admin: admin, name: name} do
      assert error_message!(fn ->
               post!(admin, %{name => [%{"unit" => %{"si" => "g"}}]})
             end) =~ "Unit (#{name}[0].unit) must be a single value"
    end

    test "required and the item bounds apply to the rows", %{admin: admin} do
      group = group!(admin, %{required: true, min_items: 2, max_items: 2})
      sub!(admin, group, %{name: "unit", label: "Unit", field_type: :string})

      assert error_message!(fn -> post!(admin, %{group.name => []}) end) =~
               "Dosages (#{group.name}) is required"

      assert error_message!(fn -> post!(admin, %{group.name => [%{"unit" => "g"}]}) end) =~
               "needs at least 2 items (has 1)"

      assert error_message!(fn ->
               post!(admin, %{group.name => List.duplicate(%{"unit" => "g"}, 3)})
             end) =~ "can have at most 2 items (has 3)"
    end

    test "a single group holds one object, and keeps the first row of a list", %{admin: admin} do
      group =
        group!(admin, %{name: "dose_#{System.unique_integer([:positive])}", multiple: false})

      sub!(admin, group, %{name: "unit", label: "Unit", field_type: :string})

      post = post!(admin, %{group.name => %{"unit" => "g"}})
      assert post.custom_fields[group.name] == %{"unit" => "g"}

      {:ok, post} =
        update_post(post, %{group.name => [%{"unit" => "ml"}, %{"unit" => "g"}]}, admin)

      assert post.custom_fields[group.name] == %{"unit" => "ml"}

      assert error_message!(fn -> post!(admin, %{group.name => %{"unit" => "g", "x" => 1}}) end) =~
               "Dosages (#{group.name}.x) is not a sub-field of this group"
    end

    test "leaving the group out keeps it; naming it replaces every row",
         %{admin: admin, name: name} do
      other =
        CMS.create_field_definition!(
          %{content_type: :post, name: "other_#{System.unique_integer([:positive])}", label: "O"},
          actor: admin
        )

      post = post!(admin, %{name => [%{"unit" => "g"}, %{"unit" => "ml"}]})

      {:ok, post} = update_post(post, %{other.name => "hi"}, admin)
      assert length(post.custom_fields[name]) == 2

      {:ok, post} = update_post(post, %{name => [%{"unit" => "ml"}]}, admin)
      assert post.custom_fields[name] == [%{"unit" => "ml", "form" => "dried"}]
    end

    test "a copy in :drop mode drops an undeclared row key instead of refusing it",
         %{admin: admin, name: name} do
      post =
        CMS.create_post!(
          %{
            title: "Copied",
            slug: slug(),
            custom_fields: %{name => [%{"unit" => "g", "gone" => "x"}]}
          },
          actor: admin,
          context: %{custom_fields: :drop}
        )

      assert post.custom_fields[name] == [%{"unit" => "g", "form" => "dried"}]
    end
  end

  describe "renaming and deleting a sub-field, flipping multiple" do
    setup %{admin: admin, name: name} do
      list = post!(admin, %{name => [%{"amount" => 1, "unit" => "g"}, %{"unit" => "ml"}]})

      single_group = group!(admin, %{multiple: false})
      note = sub!(admin, single_group, %{name: "note", label: "Note", field_type: :string})
      single = post!(admin, %{single_group.name => %{"note" => "with food"}})

      %{list: list, single: single, single_group: single_group, note: note}
    end

    test "a rename moves the key in every row", ctx do
      CMS.update_field_definition!(ctx.unit, %{name: "measure"}, actor: ctx.admin)

      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)

      assert list.custom_fields[ctx.name] == [
               %{"amount" => 1.0, "measure" => "g", "form" => "dried"},
               %{"measure" => "ml", "form" => "dried"}
             ]

      CMS.update_field_definition!(ctx.note, %{name: "remark"}, actor: ctx.admin)
      single = CMS.get_post!(ctx.single.id, actor: ctx.admin)
      assert single.custom_fields[ctx.single_group.name] == %{"remark" => "with food"}

      # Round-tripping the moved rows saves cleanly.
      assert {:ok, _} = update_post(list, list.custom_fields, ctx.admin)
    end

    test "a delete purges the key; an emptied row goes", ctx do
      CMS.destroy_field_definition!(ctx.form, actor: ctx.admin)
      CMS.destroy_field_definition!(ctx.amount, actor: ctx.admin)

      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)
      assert list.custom_fields[ctx.name] == [%{"unit" => "g"}, %{"unit" => "ml"}]

      CMS.destroy_field_definition!(ctx.unit, actor: ctx.admin)
      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)
      assert list.custom_fields[ctx.name] == []

      CMS.destroy_field_definition!(ctx.note, actor: ctx.admin)
      single = CMS.get_post!(ctx.single.id, actor: ctx.admin)
      refute Map.has_key?(single.custom_fields, ctx.single_group.name)
    end

    test "flipping multiple reshapes the stored rows", ctx do
      CMS.update_field_definition!(ctx.single_group, %{multiple: true}, actor: ctx.admin)
      single = CMS.get_post!(ctx.single.id, actor: ctx.admin)
      assert single.custom_fields[ctx.single_group.name] == [%{"note" => "with food"}]

      CMS.update_field_definition!(ctx.group, %{multiple: false}, actor: ctx.admin)
      list = CMS.get_post!(ctx.list.id, actor: ctx.admin)

      assert list.custom_fields[ctx.name] == %{
               "amount" => 1.0,
               "unit" => "g",
               "form" => "dried"
             }
    end
  end

  describe "querying" do
    test "a group answers null and nothing else", %{admin: admin, name: name} do
      with_rows = post!(admin, %{name => [%{"unit" => "g"}]})
      without = post!(admin, %{})

      present =
        %{custom_filter: %{name => %{"null" => false}}}
        |> CMS.list_posts!(actor: admin)
        |> Enum.map(& &1.id)

      assert with_rows.id in present
      refute without.id in present

      assert {:error, error} =
               CMS.list_posts(%{custom_filter: %{name => %{"eq" => "g"}}}, actor: admin)

      assert Exception.message(error) =~ "(group) only supports null"

      assert {:error, error} = CMS.list_posts(%{custom_sort: name}, actor: admin)
      assert Exception.message(error) =~ "(group) is not sortable"
    end
  end

  describe "the schema export" do
    defp field_schema(name) do
      SchemaExport.json_schema()["$defs"][SchemaExport.content_def_name(:post)]["properties"][
        "custom_fields"
      ]["properties"][name]
    end

    test "a repeating group is an array of closed objects",
         %{admin: admin, group: group, name: name} do
      CMS.update_field_definition!(group, %{max_items: 5}, actor: admin)

      assert %{
               "type" => ["array", "null"],
               "items" => %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "properties" => %{
                   "amount" => %{"type" => ["number", "null"]},
                   "unit" => %{"type" => ["string", "null"]},
                   "form" => %{"type" => ["string", "null"]}
                 }
               },
               "x-kiln-sub-fields" => ["amount", "unit", "form"],
               "x-kiln-max-items" => 5
             } = field_schema(name)
    end

    test "a single group is one nullable closed object", %{admin: admin} do
      group = group!(admin, %{multiple: false})
      sub!(admin, group, %{name: "unit", label: "Unit", field_type: :string})

      assert %{
               "type" => ["object", "null"],
               "additionalProperties" => false,
               "properties" => %{"unit" => %{"type" => ["string", "null"]}},
               "x-kiln-sub-fields" => ["unit"]
             } = field_schema(group.name)
    end

    test "the .d.ts types the rows", %{name: name} do
      ts = SchemaExport.TypeScript.emit(SchemaExport.json_schema())

      assert ts =~
               "#{name}?: Array<{ amount?: number | null; form?: string | null; unit?: string | null }> | null"
    end
  end
end
