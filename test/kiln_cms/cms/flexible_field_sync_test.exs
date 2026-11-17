defmodule KilnCMS.CMS.FlexibleFieldSyncTest do
  @moduledoc """
  Config-sync of a flexible field (#2282, PR 2): the file carries
  `"item_types"` (each an ordinary group entry with its own `"group_fields"`,
  one of which may be a flexible field with `"item_types"` of its own), and
  `"item_setting"` only when set. An export imports into an empty site and a
  second import changes nothing; a prune that would drop stored items is
  blocked without `allow_data_loss?`, and an item type holding items cannot be
  deleted by an import (it cannot pass `purge_items?`).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldSync

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flexfs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp def!(admin, attrs),
    do:
      CMS.create_field_definition!(
        Map.merge(%{label: "Field", content_type: :post}, attrs),
        actor: admin
      )

  defp item_type!(admin, flexible, name, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(
          %{name: name, field_type: :group, flex_of_id: flexible.id, content_type: nil},
          attrs
        )
      )

  defp sub!(admin, parent, name, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(
          %{name: name, group_of_id: parent.id, field_type: :string, content_type: nil},
          attrs
        )
      )

  # sections (1) > hero { headline, tone (setting), rows (2) > row { label, cells (3) > cell { text } } },
  # sections > quote { text }; a dynamic type carries one too.
  defp model!(admin) do
    sections =
      def!(admin, %{name: "sections", label: "Sections", field_type: :flexible, max_items: 8})

    hero = item_type!(admin, sections, "hero", %{label: "Hero", help_text: "A banner"})
    sub!(admin, hero, "headline", %{required: true})

    sub!(admin, hero, "tone", %{
      field_type: :select,
      options: ["dark", "light"],
      item_setting: true,
      position: 1
    })

    rows = sub!(admin, hero, "rows", %{field_type: :flexible, position: 2})
    row = item_type!(admin, rows, "row", %{max_items: 5})
    sub!(admin, row, "label")
    cells = sub!(admin, row, "cells", %{field_type: :flexible, position: 1})
    cell = item_type!(admin, cells, "cell")
    sub!(admin, cell, "text")

    quote_type = item_type!(admin, sections, "quote", %{position: 1})
    sub!(admin, quote_type, "text")

    type =
      CMS.create_type_definition!(
        %{name: "gizmo_#{System.unique_integer([:positive])}", label: "Gizmo"},
        actor: admin
      )

    blocks =
      def!(admin, %{
        type_definition_id: type.id,
        content_type: nil,
        name: "blocks",
        field_type: :flexible
      })

    part = item_type!(admin, blocks, "part")
    sub!(admin, part, "title")
    :ok
  end

  defp export!(admin) do
    {:ok, doc} = FieldSync.export(actor: admin)
    doc
  end

  defp apply!(doc, admin, opts \\ []),
    do: FieldSync.import_doc(doc, [actor: admin, apply?: true] ++ opts)

  defp wipe!(admin) do
    top =
      for f <- CMS.list_field_definitions!(actor: admin),
          KilnCMS.CMS.FieldDefinition.top_level?(f),
          do: f

    for f <- top, do: CMS.destroy_field_definition!(f, actor: admin)
  end

  defp owner(doc, kind, type),
    do: Enum.find(doc["owners"], &(&1["kind"] == kind and &1["type"] == type))

  defp field(owner, name), do: Enum.find(owner["fields"], &(&1["name"] == name))

  setup do
    {:ok, admin: user(:admin)}
  end

  describe "export" do
    test "nests item types and their sub-fields to the depth cap", %{admin: admin} do
      model!(admin)
      post = admin |> export!() |> owner("compiled", "post")
      sections = field(post, "sections")

      assert sections["field_type"] == "flexible"
      assert ["hero", "quote"] = Enum.map(sections["item_types"], & &1["name"])
      [hero, quote_type] = sections["item_types"]

      assert hero["field_type"] == "group"
      assert hero["multiple"] == true
      assert hero["help_text"] == "A banner"
      assert ["headline", "tone", "rows"] = Enum.map(hero["group_fields"], & &1["name"])
      assert ["text"] = Enum.map(quote_type["group_fields"], & &1["name"])

      rows = Enum.find(hero["group_fields"], &(&1["name"] == "rows"))
      [row] = rows["item_types"]
      assert row["max_items"] == 5
      cells = Enum.find(row["group_fields"], &(&1["name"] == "cells"))
      assert [%{"name" => "cell", "group_fields" => [%{"name" => "text"}]}] = cells["item_types"]
    end

    test "writes item_setting only when it is set", %{admin: admin} do
      model!(admin)

      hero =
        admin
        |> export!()
        |> owner("compiled", "post")
        |> field("sections")
        |> then(& &1["item_types"])
        |> hd()

      tone = Enum.find(hero["group_fields"], &(&1["name"] == "tone"))
      headline = Enum.find(hero["group_fields"], &(&1["name"] == "headline"))
      assert tone["item_setting"] == true
      refute Map.has_key?(headline, "item_setting")
      refute Map.has_key?(hero, "item_setting")
    end

    test "a site with no flexible fields exports no new key", %{admin: admin} do
      def!(admin, %{name: "plain", field_type: :string})
      doc = export!(admin)
      refute Jason.encode!(doc) =~ "item_setting"
      refute Jason.encode!(doc) =~ "item_types"
    end

    test "lists a dynamic type's flexible field too", %{admin: admin} do
      model!(admin)

      dynamic =
        admin |> export!() |> Map.fetch!("owners") |> Enum.find(&(&1["kind"] == "dynamic"))

      assert [%{"name" => "part"}] = field(dynamic, "blocks")["item_types"]
    end
  end

  describe "import" do
    test "round-trips a depth-3 model into an empty site, then is idempotent", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)
      assert export!(admin)["owners"] |> Enum.flat_map(& &1["fields"]) == []

      assert {:ok, %{applied?: true} = report} = apply!(doc, admin)
      assert report.counts[:create] > 0
      assert export!(admin) == doc

      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]
      assert export!(admin) == doc
    end

    test "the imported model validates real items", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)
      {:ok, _} = apply!(doc, admin)

      assert %{custom_fields: %{"sections" => [%{"_type" => "hero", "headline" => "H"} = item]}} =
               CMS.create_post!(
                 %{
                   title: "T",
                   slug: "flexfs-#{System.unique_integer([:positive])}",
                   custom_fields: %{
                     "sections" => [
                       %{
                         "_type" => "hero",
                         "headline" => "H",
                         "_settings" => %{"tone" => "dark"},
                         "rows" => [
                           %{
                             "_type" => "row",
                             "label" => "R",
                             "cells" => [%{"_type" => "cell", "text" => "c"}]
                           }
                         ]
                       }
                     ]
                   }
                 },
                 actor: admin
               )

      assert item["_settings"] == %{"tone" => "dark"}
      assert [%{"cells" => [%{"text" => "c"}]}] = item["rows"]
    end

    test "an item type edited in the file is an update of only that item type", %{admin: admin} do
      model!(admin)

      doc =
        update_in(export!(admin), ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections" do
            update_in(f, ["item_types", Access.filter(&(&1["name"] == "quote")), "label"], fn _ ->
              "Pull quote"
            end)
          else
            f
          end
        end)

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin)

      assert [%{path: "post.sections.quote", changes: %{"label" => _}}] =
               Enum.filter(report.ops, &(&1.op == :update))
    end

    test "a hand-written item type may leave out field_type and multiple", %{admin: admin} do
      doc = %{
        "format" => FieldSync.format(),
        "version" => FieldSync.version(),
        "owners" => [
          %{
            "kind" => "compiled",
            "type" => "post",
            "fields" => [
              %{
                "name" => "blocks",
                "label" => "Blocks",
                "field_type" => "flexible",
                "item_types" => [
                  %{
                    "name" => "teaser",
                    "label" => "Teaser",
                    "group_fields" => [
                      %{"name" => "color", "label" => "Color", "item_setting" => true}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:ok, %{applied?: true}} = apply!(doc, admin)
      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]

      teaser =
        admin
        |> export!()
        |> owner("compiled", "post")
        |> field("blocks")
        |> Map.fetch!("item_types")
        |> hd()

      assert teaser["field_type"] == "group"
      assert [%{"name" => "color", "item_setting" => true}] = teaser["group_fields"]
    end

    test "refuses item_types on a field that is not flexible, and a non-group item type",
         %{admin: admin} do
      model!(admin)

      on_plain =
        put_in(
          export!(admin),
          ["owners", Access.at(0), "fields", Access.at(0), "item_types"],
          []
        )

      on_plain =
        update_in(
          on_plain,
          ["owners", Access.at(0), "fields", Access.at(0)],
          &Map.put(&1, "field_type", "string")
        )

      assert {:error, %{errors: [%{messages: [message]}]}} =
               FieldSync.import_doc(on_plain, actor: admin)

      assert message =~ "only belongs to a flexible field"

      bad =
        export!(admin)
        |> update_in(["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections" do
            update_in(
              f,
              ["item_types", Access.at(0)],
              &(&1 |> Map.put("field_type", "string") |> Map.delete("group_fields"))
            )
          else
            f
          end
        end)

      assert {:error, %{errors: [%{messages: [message]}]}} =
               FieldSync.import_doc(bad, actor: admin)

      assert message =~ "an item type is a \"group\""
    end

    test "the import is admin only", %{admin: admin} do
      model!(admin)
      assert {:error, :forbidden} = FieldSync.import_doc(export!(admin), actor: user(:editor))
    end
  end

  describe "prune and data loss" do
    setup %{admin: admin} do
      model!(admin)
      sections = CMS.list_field_definitions!(actor: admin) |> Enum.find(&(&1.name == "sections"))

      post =
        CMS.create_post!(
          %{
            title: "T",
            slug: "flexfs-#{System.unique_integer([:positive])}",
            custom_fields: %{
              "sections" => [
                %{"_type" => "hero", "headline" => "H"},
                %{"_type" => "quote", "text" => "Q"}
              ]
            }
          },
          actor: admin
        )

      %{sections: sections, post: post}
    end

    defp drop_item_type(doc, name),
      do:
        update_in(doc, ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections",
            do: Map.update!(f, "item_types", fn ts -> Enum.reject(ts, &(&1["name"] == name)) end),
            else: f
        end)

    defp item_type_names(admin) do
      for f <- CMS.list_field_definitions!(actor: admin),
          KilnCMS.CMS.FieldDefinition.item_type?(f),
          do: f.name
    end

    test "an item type missing from the file is kept unless pruned", %{admin: admin} do
      doc = admin |> export!() |> drop_item_type("quote")

      assert {:ok, report} = apply!(doc, admin)
      assert "post.sections.quote" in report.untouched
      assert "quote" in item_type_names(admin)
    end

    test "pruning an item type that holds items is blocked without the flag", %{
      admin: admin,
      post: post
    } do
      doc = admin |> export!() |> drop_item_type("quote")

      assert {:error, %{blocked: [%{path: "post.sections.quote"}]}} =
               apply!(doc, admin, prune?: true)

      assert "quote" in item_type_names(admin)
      assert length(CMS.get_post!(post.id, actor: admin).custom_fields["sections"]) == 2
    end

    test "with the flag the destroy is still refused: an import cannot pass purge_items?",
         %{admin: admin, post: post} do
      doc = admin |> export!() |> drop_item_type("quote")

      assert {:error, %{errors: [%{path: "post.sections.quote", messages: [message]}]}} =
               apply!(doc, admin, prune?: true, allow_data_loss?: true)

      assert message =~ "purge_items?"
      assert "quote" in item_type_names(admin)
      assert length(CMS.get_post!(post.id, actor: admin).custom_fields["sections"]) == 2
    end

    test "pruning an item type no item uses is allowed", %{admin: admin, post: post} do
      CMS.update_post!(
        post,
        %{custom_fields: %{"sections" => [%{"_type" => "hero", "headline" => "H"}]}},
        actor: admin
      )

      doc = admin |> export!() |> drop_item_type("quote")
      assert {:ok, _} = apply!(doc, admin, prune?: true)
      refute "quote" in item_type_names(admin)
    end

    test "pruning a sub-field of an item type that holds items is blocked", %{admin: admin} do
      doc =
        update_in(export!(admin), ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections" do
            update_in(
              f,
              ["item_types", Access.filter(&(&1["name"] == "quote")), "group_fields"],
              fn _ -> [] end
            )
          else
            f
          end
        end)

      assert {:error, %{blocked: [%{path: "post.sections.quote.text"}]}} =
               apply!(doc, admin, prune?: true)
    end

    test "pruning a sub-field of an item type with no items is allowed", %{admin: admin} do
      # `cell` has no stored items, `hero` does: its nested sub-field is judged by its own type
      doc =
        update_in(export!(admin), ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections" do
            update_in(
              f,
              [
                "item_types",
                Access.filter(&(&1["name"] == "hero")),
                "group_fields",
                Access.filter(&(&1["name"] == "rows")),
                "item_types",
                Access.at(0),
                "group_fields",
                Access.filter(&(&1["name"] == "cells")),
                "item_types",
                Access.at(0),
                "group_fields"
              ],
              fn _ -> [] end
            )
          else
            f
          end
        end)

      assert {:ok, _} = apply!(doc, admin, prune?: true)
    end

    test "deleting a whole flexible field that holds items is blocked without the flag", %{
      admin: admin,
      post: post
    } do
      doc =
        update_in(export!(admin), ["owners", Access.all(), "fields"], fn fs ->
          Enum.reject(fs, &(&1["name"] == "sections"))
        end)

      assert {:error, %{blocked: [%{path: "post.sections"}]}} = apply!(doc, admin, prune?: true)
      assert length(CMS.get_post!(post.id, actor: admin).custom_fields["sections"]) == 2

      assert {:ok, _} = apply!(doc, admin, prune?: true, allow_data_loss?: true)
      refute Map.has_key?(CMS.get_post!(post.id, actor: admin).custom_fields, "sections")
      assert item_type_names(admin) -- ["part"] == []
    end

    test "flipping item_setting over stored items is blocked", %{admin: admin} do
      doc =
        update_in(export!(admin), ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections" do
            update_in(
              f,
              [
                "item_types",
                Access.filter(&(&1["name"] == "quote")),
                "group_fields",
                Access.all()
              ],
              &Map.put(&1, "item_setting", true)
            )
          else
            f
          end
        end)

      assert {:error, %{blocked: [%{path: "post.sections.quote.text"}]}} =
               FieldSync.import_doc(doc, actor: admin)
    end
  end

  describe "retyping through an import" do
    test "to or from flexible is refused by the resource, flag or not", %{admin: admin} do
      model!(admin)

      to_string_doc =
        update_in(export!(admin), ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "sections",
            do: f |> Map.put("field_type", "text") |> Map.drop(["item_types"]),
            else: f
        end)

      assert {:error, %{errors: [%{path: "post.sections", messages: [message]}]}} =
               apply!(to_string_doc, admin, allow_data_loss?: true)

      assert message =~ "to or from a flexible field"
    end
  end
end
