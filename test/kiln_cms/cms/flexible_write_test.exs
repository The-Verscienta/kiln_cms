defmodule KilnCMS.CMS.FlexibleWriteTest do
  @moduledoc """
  The write path of a `:flexible` custom field (#2282,
  `docs/flexible-content-plan.md` sections 3 and 4): `ApplyCustomFields`
  coerces a list of `%{"_id", "_type", "_settings", ...}` items by their item
  types. Covers the stored shape, `_id` minting and keeping, per-type
  coercion with error paths, settings, conditions and constraints, blank
  items, bounds, nesting down to the cap, the strict and `:drop` modes, the
  grandfathering of stored items, copies, imports and field grants.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Portability.Import

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "flexw-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "flexw-#{System.unique_integer([:positive])}"

  defp def!(admin, attrs) do
    CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)
  end

  defp flexible!(admin, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(%{content_type: :post, name: "sections", field_type: :flexible}, attrs)
      )

  defp item_type!(admin, flexible, name, attrs),
    do:
      def!(
        admin,
        Map.merge(%{name: name, field_type: :group, flex_of_id: flexible.id}, attrs)
      )

  defp sub!(admin, parent, name, attrs \\ %{}),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp post!(admin, fields),
    do: CMS.create_post!(%{title: "Page", slug: slug(), custom_fields: fields}, actor: admin)

  defp update_post(post, fields, admin, opts \\ []),
    do: CMS.update_post(post, %{custom_fields: fields}, [actor: admin] ++ opts)

  defp message!(fun), do: Exception.message(assert_raise(Ash.Error.Invalid, fun))

  defp stored(post, admin), do: CMS.get_post!(post.id, actor: admin).custom_fields

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  setup do
    admin = user(:admin)
    flexible = flexible!(admin)
    hero = item_type!(admin, flexible, "hero", %{label: "Hero"})
    quote_type = item_type!(admin, flexible, "quote", %{label: "Quote", position: 1})

    sub!(admin, hero, "headline", %{label: "Headline", required: true})

    sub!(admin, hero, "background", %{
      label: "Background",
      field_type: :select,
      options: ["dark", "light"],
      item_setting: true,
      position: 1
    })

    sub!(admin, quote_type, "text", %{label: "Text"})
    sub!(admin, quote_type, "cite", %{label: "Cite", position: 1})

    %{admin: admin, flexible: flexible, hero: hero, quote_type: quote_type}
  end

  describe "the stored shape" do
    test "items are kept in order with _id, _type and settings in _settings", %{admin: admin} do
      post =
        post!(admin, %{
          "sections" => [
            %{
              "_type" => "hero",
              "headline" => "Hello",
              "_settings" => %{"background" => "dark"}
            },
            %{"_type" => "quote", "text" => "Be brief", "cite" => "Me"}
          ]
        })

      assert %{"sections" => [hero, quote_item]} = stored(post, admin)

      assert %{"_type" => "hero", "headline" => "Hello", "_settings" => %{"background" => "dark"}} =
               hero

      assert uuid?(hero["_id"])
      assert quote_item["_type"] == "quote"
      assert quote_item["text"] == "Be brief"
      refute Map.has_key?(quote_item, "_settings")
      assert hero["_id"] != quote_item["_id"]
    end

    test "an omitted flexible key keeps the stored list; a blank one clears it", %{admin: admin} do
      post = post!(admin, %{"sections" => [%{"_type" => "quote", "text" => "x"}]})
      kept = stored(post, admin)["sections"]

      assert {:ok, updated} = update_post(post, %{}, admin)
      assert updated.custom_fields["sections"] == kept

      assert {:ok, cleared} = update_post(updated, %{"sections" => []}, admin)
      refute Map.has_key?(cleared.custom_fields, "sections")
    end

    test "a blank string is an empty list: it clears, and is not refused", %{admin: admin} do
      post = post!(admin, %{"sections" => [%{"_type" => "quote", "text" => "x"}]})

      assert {:ok, cleared} = update_post(post, %{"sections" => ""}, admin)
      refute Map.has_key?(cleared.custom_fields, "sections")
    end

    test "atom keys are accepted like string keys", %{admin: admin} do
      post = post!(admin, %{sections: [%{_type: "quote", text: "atoms"}]})
      assert [%{"_type" => "quote", "text" => "atoms"}] = stored(post, admin)["sections"]
    end

    test "a value that is not a list is refused", %{admin: admin} do
      assert message!(fn -> post!(admin, %{"sections" => %{"_type" => "hero"}}) end) =~
               "must be a list of items"
    end
  end

  describe "_id" do
    test "a UUID is kept across writes and a write merges strictly by it", %{admin: admin} do
      post =
        post!(admin, %{
          "sections" => [
            %{"_type" => "quote", "text" => "one"},
            %{"_type" => "quote", "text" => "two"}
          ]
        })

      [one, two] = stored(post, admin)["sections"]

      # reorder, edit one, drop none
      {:ok, post} =
        update_post(
          post,
          %{"sections" => [Map.put(two, "text", "TWO"), one]},
          admin
        )

      assert [%{"_id" => id2, "text" => "TWO"}, %{"_id" => id1}] = post.custom_fields["sections"]
      assert {id1, id2} == {one["_id"], two["_id"]}

      # an item the write omits is removed
      {:ok, post} = update_post(post, %{"sections" => [one]}, admin)
      assert [%{"_id" => ^id1}] = post.custom_fields["sections"]
    end

    test "an absent, malformed or repeated _id gets a fresh one", %{admin: admin} do
      dup = Ash.UUID.generate()

      post =
        post!(admin, %{
          "sections" => [
            %{"_type" => "quote", "text" => "a", "_id" => dup},
            %{"_type" => "quote", "text" => "b", "_id" => dup},
            %{"_type" => "quote", "text" => "c", "_id" => "not-a-uuid"},
            %{"_type" => "quote", "text" => "d", "_id" => 42},
            %{"_type" => "quote", "text" => "e"}
          ]
        })

      ids = Enum.map(stored(post, admin)["sections"], & &1["_id"])
      assert hd(ids) == dup
      assert Enum.all?(ids, &uuid?/1)
      assert length(Enum.uniq(ids)) == 5
    end

    test "an item without an _id (stored before ids existed) is tolerated", %{admin: admin} do
      post = post!(admin, %{"sections" => [%{"_type" => "quote", "text" => "x"}]})
      # strip the id from the stored row, as a value written before ids was
      legacy =
        Ash.Seed.update!(post, %{
          custom_fields: %{"sections" => [%{"_type" => "quote", "text" => "x"}]}
        })

      # an identical resend is no change at all (Ash drops it); a real edit saves
      # the id-less item as it is and gives it an id.
      same = %{"_type" => "quote", "text" => "x"}

      assert {:ok, updated} =
               update_post(
                 legacy,
                 %{"sections" => [same, %{"_type" => "quote", "text" => "y"}]},
                 admin
               )

      assert [%{"_id" => id}, %{"_id" => id2}] = updated.custom_fields["sections"]
      assert uuid?(id) and uuid?(id2)
    end
  end

  describe "coercion and error paths" do
    test "an unknown _type is refused under its path in strict mode", %{admin: admin} do
      msg =
        message!(fn ->
          post!(admin, %{
            "sections" => [
              %{"_type" => "quote", "text" => "ok"},
              %{"_type" => "hero", "headline" => "h"},
              %{"_type" => "banner", "headline" => "x"}
            ]
          })
        end)

      assert msg =~ "sections[2]._type"
      assert msg =~ "banner"
      assert msg =~ "item types: hero, quote"
    end

    test "a missing _type is refused", %{admin: admin} do
      assert message!(fn -> post!(admin, %{"sections" => [%{"headline" => "x"}]}) end) =~
               "sections[0]._type"
    end

    test "an item that is not an object is refused", %{admin: admin} do
      assert message!(fn -> post!(admin, %{"sections" => ["oops"]}) end) =~ "sections[0]"
    end

    test "required, :select and unknown keys are checked under the item's path", %{admin: admin} do
      msg =
        message!(fn ->
          post!(admin, %{
            "sections" => [
              %{"_type" => "quote", "text" => "ok"},
              %{
                "_type" => "hero",
                "headline" => "",
                "extra" => "nope",
                "_settings" => %{"background" => "neon", "ghost" => "boo"}
              }
            ]
          })
        end)

      assert msg =~ "sections[1].headline"
      assert msg =~ "is required"
      assert msg =~ "sections[1]._settings.background"
      assert msg =~ "sections[1].extra"
      assert msg =~ "sections[1]._settings.ghost"
    end

    test "a settings key sent as content, and a non-object _settings, are refused", %{
      admin: admin
    } do
      assert message!(fn ->
               post!(admin, %{
                 "sections" => [%{"_type" => "hero", "headline" => "h", "background" => "dark"}]
               })
             end) =~ "sections[0].background"

      assert message!(fn ->
               post!(admin, %{
                 "sections" => [%{"_type" => "hero", "headline" => "h", "_settings" => "dark"}]
               })
             end) =~ "sections[0]._settings"
    end

    test "a blank item is dropped, whatever its _type and _id", %{admin: admin} do
      post =
        post!(admin, %{
          "sections" => [
            %{"_type" => "hero", "_id" => Ash.UUID.generate(), "headline" => ""},
            %{"_type" => "quote", "text" => "kept"},
            %{"_type" => "quote", "text" => "  "}
          ]
        })

      assert [%{"text" => "kept"}] = stored(post, admin)["sections"]
    end

    test "a flexible field with only blank items is empty (required fails)", %{admin: admin} do
      def!(admin, %{content_type: :page, name: "req", field_type: :flexible, required: true})

      assert message!(fn ->
               CMS.create_page!(
                 %{title: "P", slug: slug(), custom_fields: %{"req" => [%{"_type" => "x"}]}},
                 actor: admin
               )
             end) =~ "is required"
    end
  end

  describe "conditions and constraints" do
    test "a sub-field's required_when sees its own item's fields", %{
      admin: admin,
      quote_type: quote_type
    } do
      sub!(admin, quote_type, "kind", %{label: "Kind", position: 2})

      sub!(admin, quote_type, "source_url", %{
        label: "Source URL",
        position: 3,
        required_when: %{"field" => "kind", "op" => "eq", "value" => "web"}
      })

      assert message!(fn ->
               post!(admin, %{
                 "sections" => [
                   %{"_type" => "quote", "text" => "a", "kind" => "print"},
                   %{"_type" => "quote", "text" => "b", "kind" => "web"}
                 ]
               })
             end) =~ "sections[1].source_url"

      assert %{"sections" => [_, _]} =
               stored(
                 post!(admin, %{
                   "sections" => [
                     %{"_type" => "quote", "text" => "a", "kind" => "print"},
                     %{"_type" => "quote", "text" => "b", "kind" => "web", "source_url" => "u"}
                   ]
                 }),
                 admin
               )
    end

    test "constraints apply to new items and grandfather stored ones", %{
      admin: admin,
      quote_type: quote_type
    } do
      text = CMS.field_definitions_for!(:post, actor: admin) |> text_sub(quote_type)

      post = post!(admin, %{"sections" => [%{"_type" => "quote", "text" => "ab"}]})
      [item] = stored(post, admin)["sections"]

      # tighten after the fact
      CMS.update_field_definition!(text, %{validation: %{"min_length" => 5}}, actor: admin)

      # the stored item re-sent (even with another _id) still saves
      assert {:ok, post} =
               update_post(post, %{"sections" => [Map.delete(item, "_id")]}, admin)

      # a new item under the new rule does not
      assert message!(fn ->
               update_post(
                 post,
                 %{"sections" => [item, %{"_type" => "quote", "text" => "xy"}]},
                 admin
               )
               |> case do
                 {:error, error} -> raise error
                 other -> other
               end
             end) =~ "sections[1].text"
    end
  end

  defp text_sub(defs, quote_type) do
    defs
    |> Enum.find(&(&1.name == "sections"))
    |> KilnCMS.CMS.FieldDefinition.item_types()
    |> Enum.find(&(&1.id == quote_type.id))
    |> KilnCMS.CMS.FieldDefinition.group_fields()
    |> Enum.find(&(&1.name == "text"))
  end

  describe "bounds" do
    test "min_items and max_items on the field", %{admin: admin, flexible: flexible} do
      CMS.update_field_definition!(flexible, %{min_items: 2, max_items: 3}, actor: admin)
      q = fn n -> %{"_type" => "quote", "text" => "q#{n}"} end

      assert message!(fn -> post!(admin, %{"sections" => [q.(1)]}) end) =~
               "needs at least 2 items (has 1)"

      assert message!(fn -> post!(admin, %{"sections" => Enum.map(1..4, q)}) end) =~
               "can have at most 3 items (has 4)"

      assert post!(admin, %{"sections" => Enum.map(1..3, q)})
    end

    test "max_items on an item type", %{admin: admin, quote_type: quote_type} do
      CMS.update_field_definition!(quote_type, %{max_items: 1}, actor: admin)
      q = fn n -> %{"_type" => "quote", "text" => "q#{n}"} end

      msg = message!(fn -> post!(admin, %{"sections" => [q.(1), q.(2)]}) end)
      assert msg =~ "sections"
      assert msg =~ "at most 1 quote items (has 2)"

      assert post!(admin, %{"sections" => [q.(1), %{"_type" => "hero", "headline" => "h"}]})
    end

    test "a field with no max_items still caps at 100 items", %{admin: admin} do
      q = fn n -> %{"_type" => "quote", "text" => "q#{n}"} end

      assert post!(admin, %{"sections" => Enum.map(1..100, q)})

      assert message!(fn -> post!(admin, %{"sections" => Enum.map(1..101, q)}) end) =~
               "can have at most 100 items (has 101)"
    end
  end

  describe "nesting" do
    # sections (1) > section.rows (2) > row.cells (3) > cell.text
    setup %{admin: admin, flexible: l1} do
      section = item_type!(admin, l1, "section", %{label: "Section", position: 2})
      sub!(admin, section, "title", %{label: "Title"})
      rows = sub!(admin, section, "rows", %{label: "Rows", field_type: :flexible, position: 1})
      row = item_type!(admin, rows, "row", %{label: "Row"})
      cells = sub!(admin, row, "cells", %{label: "Cells", field_type: :flexible})
      cell = item_type!(admin, cells, "cell", %{label: "Cell"})
      sub!(admin, cell, "text", %{label: "Text"})
      %{section: section, rows: rows, cells: cells}
    end

    defp three_levels(extra \\ %{}) do
      [
        %{
          "_type" => "section",
          "title" => "S",
          "rows" => [
            %{
              "_type" => "row",
              "cells" => [%{"_type" => "cell", "text" => "t"} |> Map.merge(extra)]
            }
          ]
        }
      ]
    end

    test "three levels coerce, get ids at every level, and keep them", %{admin: admin} do
      post = post!(admin, %{"sections" => three_levels()})

      assert [
               %{"_id" => a, "rows" => [%{"_id" => b, "cells" => [%{"_id" => c, "text" => "t"}]}]} =
                 section
             ] =
               stored(post, admin)["sections"]

      assert Enum.all?([a, b, c], &uuid?/1)

      {:ok, again} = update_post(post, %{"sections" => [section]}, admin)
      assert again.custom_fields["sections"] == [section]
    end

    test "errors carry the whole path down the tree", %{admin: admin} do
      msg =
        message!(fn ->
          post!(admin, %{
            "sections" => [
              %{"_type" => "quote", "text" => "x"},
              %{
                "_type" => "section",
                "title" => "S",
                "rows" => [
                  %{"_type" => "row", "cells" => [%{"_type" => "cell", "text" => "ok"}]},
                  %{
                    "_type" => "row",
                    "cells" => [
                      %{"_type" => "cell", "text" => "ok"},
                      %{"_type" => "wide", "text" => "no"}
                    ]
                  }
                ]
              }
            ]
          })
        end)

      assert msg =~ "sections[1].rows[1].cells[1]._type"
    end

    test "a fourth level is not a field: the key is refused", %{admin: admin} do
      msg =
        message!(fn ->
          post!(admin, %{
            "sections" => three_levels(%{"blocks" => [%{"_type" => "x", "a" => "b"}]})
          })
        end)

      assert msg =~ "sections[0].rows[0].cells[0].blocks"
    end

    test "the cap on the definition side is the same three levels", %{admin: admin, cells: cells} do
      cell = item_type!(admin, cells, "cell2", %{label: "Cell 2"})

      assert_raise Ash.Error.Invalid, ~r/nest at most 3 levels/, fn ->
        sub!(admin, cell, "deeper", %{label: "Deeper", field_type: :flexible})
      end
    end

    test "bounds hold at every level", %{admin: admin, rows: rows} do
      CMS.update_field_definition!(rows, %{max_items: 1}, actor: admin)
      row = %{"_type" => "row", "cells" => [%{"_type" => "cell", "text" => "t"}]}

      assert message!(fn ->
               post!(admin, %{
                 "sections" => [%{"_type" => "section", "title" => "S", "rows" => [row, row]}]
               })
             end) =~ "sections[0].rows"
    end
  end

  describe "strict and :drop modes (copy, restore)" do
    test "a stored item of a type no longer defined is refused in strict and dropped in :drop", %{
      admin: admin
    } do
      post = post!(admin, %{"sections" => [%{"_type" => "quote", "text" => "keep"}]})

      value = [
        %{"_id" => Ash.UUID.generate(), "_type" => "retired", "text" => "old"}
        | post.custom_fields["sections"]
      ]

      seeded = Ash.Seed.update!(post, %{custom_fields: %{"sections" => value}})

      # (an identical resend would be no change at all, so the write adds an item)
      sent = value ++ [%{"_type" => "quote", "text" => "new"}]

      assert {:error, error} = update_post(seeded, %{"sections" => sent}, admin)
      assert Exception.message(error) =~ "sections[0]._type"

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, dropped} =
                 update_post(seeded, %{"sections" => sent}, admin,
                   context: %{custom_fields: :drop}
                 )

        assert [%{"text" => "keep"}, %{"text" => "new"}] = dropped.custom_fields["sections"]
      end)
    end

    test "a translation copy carries the whole flexible value", %{admin: admin} do
      post =
        post!(admin, %{
          "sections" => [
            %{"_type" => "hero", "headline" => "H", "_settings" => %{"background" => "light"}},
            %{"_type" => "quote", "text" => "Q"}
          ]
        })

      post = CMS.get_post!(post.id, actor: admin)

      {copy, _notes} =
        KilnCMS.CMS.Translations.create_translation_with_notes!(:post, post, "fr",
          actor: admin,
          tenant: post.org_id
        )

      assert stored(copy, admin)["sections"] == post.custom_fields["sections"]
    end
  end

  describe "import" do
    defp envelope(fields),
      do: %{
        "records" => [
          %{"type" => "post", "title" => "Imported", "slug" => slug(), "custom_fields" => fields}
        ]
      }

    test "a JSON import keeps each item's _id", %{admin: admin} do
      id = Ash.UUID.generate()
      org = post!(admin, %{}).org_id

      {:ok, report} =
        Import.run_envelope(
          envelope(%{"sections" => [%{"_id" => id, "_type" => "quote", "text" => "in"}]}),
          actor: admin,
          tenant: org,
          skip_media: true
        )

      assert report.failed == []
      [created] = report.created

      assert [%{"_id" => ^id, "_type" => "quote", "text" => "in"}] =
               stored(%{id: created.id}, admin)["sections"]
    end

    test "a row whose item breaks its type fails with the item's path", %{admin: admin} do
      {:ok, report} =
        Import.run_envelope(
          envelope(%{
            "sections" => [
              %{"_type" => "hero", "headline" => "h", "_settings" => %{"background" => "neon"}}
            ]
          }),
          actor: admin,
          tenant: post!(admin, %{}).org_id,
          skip_media: true
        )

      assert [failed] = report.failed
      assert inspect(failed) =~ "sections[0]._settings.background"
    end

    test "an item of a type this site lacks fails the row with its path, naming the types", %{
      admin: admin
    } do
      {:ok, report} =
        Import.run_envelope(
          envelope(%{
            "sections" => [
              %{"_type" => "quote", "text" => "ok"},
              %{"_type" => "banner", "headline" => "x"}
            ]
          }),
          actor: admin,
          tenant: post!(admin, %{}).org_id,
          skip_media: true
        )

      assert report.created == []
      assert [failed] = report.failed
      assert inspect(failed) =~ "sections[1]._type"
      assert inspect(failed) =~ "banner"
      assert inspect(failed) =~ "hero, quote"
    end

    test "an import still drops an unknown key, as it did before item types", %{admin: admin} do
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, report} =
          Import.run_envelope(
            envelope(%{"nope" => "x", "sections" => [%{"_type" => "quote", "text" => "kept"}]}),
            actor: admin,
            tenant: post!(admin, %{}).org_id,
            skip_media: true
          )

        assert report.failed == []
        [created] = report.created
        assert [%{"text" => "kept"}] = stored(%{id: created.id}, admin)["sections"]
      end)
    end
  end

  describe "dynamic types" do
    test "a flexible field on a dynamic type writes the same way", %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: "gadget_#{System.unique_integer([:positive])}", label: "Gadget"},
          actor: admin
        )

      blocks =
        def!(admin, %{type_definition_id: type.id, name: "blocks", field_type: :flexible})

      note = item_type!(admin, blocks, "note", %{label: "Note"})
      sub!(admin, note, "body", %{label: "Body"})

      entry =
        CMS.create_entry!(
          %{
            title: "E",
            slug: slug(),
            type_definition_id: type.id,
            custom_fields: %{"blocks" => [%{"_type" => "note", "body" => "dyn"}]}
          },
          actor: admin
        )

      assert [%{"_type" => "note", "body" => "dyn", "_id" => id}] =
               CMS.get_entry!(entry.id, actor: admin).custom_fields["blocks"]

      assert uuid?(id)
    end
  end

  describe "field grants (per-key grants arrive with the editor, a later PR)" do
    test "a custom_fields.sections grant lets an editor write the field", %{admin: admin} do
      editor = user(:editor, %{field_grants: %{"post" => ["title", "custom_fields.sections"]}})

      post = post!(admin, %{})

      assert {:ok, updated} =
               update_post(post, %{"sections" => [%{"_type" => "quote", "text" => "e"}]}, editor)

      assert [%{"text" => "e"}] = updated.custom_fields["sections"]
    end

    test "a custom_fields.sections.hero grant is not understood and writes nothing", %{
      admin: admin
    } do
      editor =
        user(:editor, %{field_grants: %{"post" => ["title", "custom_fields.sections.hero"]}})

      post = post!(admin, %{})

      assert {:error, _} =
               update_post(
                 post,
                 %{"sections" => [%{"_type" => "hero", "headline" => "h"}]},
                 editor
               )
    end
  end

  describe "cost" do
    test "a 50-item, 8-field value coerces in one write", %{admin: admin, flexible: flexible} do
      wide = item_type!(admin, flexible, "wide", %{label: "Wide", position: 5})
      for n <- 1..8, do: sub!(admin, wide, "f#{n}", %{label: "F#{n}", position: n})

      items =
        for i <- 1..50 do
          Map.merge(%{"_type" => "wide"}, Map.new(1..8, &{"f#{&1}", "value #{i}-#{&1}"}))
        end

      {micros, post} = :timer.tc(fn -> post!(admin, %{"sections" => items}) end)

      {resend_micros, _} =
        :timer.tc(fn ->
          update_post(post, %{"sections" => post.custom_fields["sections"]}, admin)
        end)

      assert length(post.custom_fields["sections"]) == 50

      IO.puts(
        "flexible 50x8 create: #{div(micros, 1000)} ms, unchanged re-save: #{div(resend_micros, 1000)} ms"
      )
    end

    test "reading definitions on a type with no flexible field", %{admin: admin} do
      def!(admin, %{content_type: :page, name: "plain_a", field_type: :string})
      {micros, defs} = :timer.tc(fn -> CMS.field_definitions_for!(:page, actor: admin) end)
      assert length(defs) == 1
      IO.puts("for_type, zero flexible fields: #{div(micros, 1000)} ms")
    end
  end
end
