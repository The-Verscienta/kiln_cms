defmodule KilnCMSWeb.FlexibleItemsTest do
  @moduledoc """
  `KilnCMSWeb.ContentEditor.FlexibleItems` (#2282): the wire form folded into
  an ordered list that keeps `_id`, `_type` and `_settings`, recursion into
  nested flexible sub-fields, orphans reduced to inert markers, the edits by
  `_id`, blank-card detection for autosave, and error paths resolved to
  addresses.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ContentEditor.FlexibleItems

  defp sub(name, attrs \\ %{}),
    do:
      Map.merge(
        %{name: name, label: String.capitalize(name), field_type: :string, item_setting: false},
        attrs
      )

  defp type(name, subs, attrs \\ %{}),
    do:
      Map.merge(
        %{name: name, label: String.capitalize(name), field_type: :group, group_fields: subs},
        attrs
      )

  defp flexible(name, types, attrs \\ %{}),
    do:
      Map.merge(
        %{name: name, label: String.capitalize(name), field_type: :flexible, item_types: types},
        attrs
      )

  defp definition do
    notes = flexible("notes", [type("note", [sub("text")])])
    cells = flexible("cells", [type("cell", [sub("label"), notes])])

    flexible("sections", [
      type("hero", [sub("headline"), sub("theme", %{item_setting: true})]),
      type("columns", [cells]),
      type("quote", [sub("text")], %{max_items: 1})
    ])
  end

  defp normalize(sections) do
    %{"custom_fields" => %{"sections" => sections}}
    |> FlexibleItems.normalize([definition()])
    |> get_in(["custom_fields", "sections"])
  end

  describe "normalize/2" do
    test "folds the position map into an ordered list, keeping the meta keys" do
      assert [
               %{
                 "_id" => "a",
                 "_type" => "hero",
                 "headline" => "one",
                 "_settings" => %{"theme" => "dark"}
               },
               %{"_id" => "b", "_type" => "quote", "text" => "two"}
             ] =
               normalize(%{
                 "10" => %{"_id" => "b", "_type" => "quote", "text" => "two"},
                 "2" => %{
                   "_id" => "a",
                   "_type" => "hero",
                   "headline" => "one",
                   "_settings" => %{"theme" => "dark"}
                 }
               })
    end

    test "drops the blank markers and LiveView's _unused_ companions, at every level" do
      [item] =
        normalize(%{
          "_" => "",
          "0" => %{
            "_id" => "a",
            "_type" => "hero",
            "_unused_headline" => "",
            "headline" => "x",
            "_settings" => %{"_unused_theme" => "", "theme" => "dark"}
          }
        })

      assert item == %{
               "_id" => "a",
               "_type" => "hero",
               "headline" => "x",
               "_settings" => %{"theme" => "dark"}
             }
    end

    test "recurses into nested flexible lists to the cap" do
      assert [
               %{
                 "cells" => [
                   %{"label" => "l", "notes" => [%{"_type" => "note", "text" => "t"}]}
                 ]
               }
             ] =
               normalize(%{
                 "0" => %{
                   "_type" => "columns",
                   "cells" => %{
                     "_" => "",
                     "0" => %{
                       "_type" => "cell",
                       "label" => "l",
                       "notes" => %{"0" => %{"_type" => "note", "text" => "t", "_row" => ""}}
                     }
                   }
                 }
               })
    end

    test "an orphan keeps only its id and type; an item with no type is left for the save" do
      assert [%{"_id" => "o", "_type" => "gone"} = orphan, %{"headline" => "x"} = untyped] =
               normalize(%{
                 "0" => %{"_id" => "o", "_type" => "gone", "headline" => "secret"},
                 "1" => %{"headline" => "x"}
               })

      assert map_size(orphan) == 2
      refute Map.has_key?(untyped, "_type")
    end

    test "lists, absent fields and other fields pass through" do
      params = %{"custom_fields" => %{"other" => %{"0" => %{"a" => "b"}}}}
      assert FlexibleItems.normalize(params, [definition()]) == params
      assert FlexibleItems.normalize(%{"title" => "x"}, [definition()]) == %{"title" => "x"}
      assert [%{"_type" => "quote"}] = normalize([%{"_type" => "quote", "_row" => ""}])
      assert normalize("junk") == "junk"
    end
  end

  describe "edits by _id" do
    setup do
      %{
        items: [
          %{"_id" => "a", "_type" => "hero"},
          %{"_id" => "b", "_type" => "quote"},
          %{"_id" => "c", "_type" => "columns", "cells" => [%{"_id" => "d", "_type" => "cell"}]}
        ]
      }
    end

    test "add takes a known type, and refuses a full type or an unknown one", %{items: items} do
      assert {:ok, [_, _, _, %{"_type" => "hero", "_id" => id}]} =
               FlexibleItems.add(items, definition(), "hero")

      assert {:ok, _} = Ecto.UUID.cast(id)
      assert :error = FlexibleItems.add(items, definition(), "quote")
      assert :error = FlexibleItems.add(items, definition(), "ghost")
      assert :error = FlexibleItems.add(items, Map.put(definition(), :max_items, 3), "hero")
    end

    test "move swaps neighbours and stops at the ends", %{items: items} do
      assert {:ok, [%{"_id" => "b"}, %{"_id" => "a"}, _]} = FlexibleItems.move(items, "b", "up")
      assert :error = FlexibleItems.move(items, "a", "up")
      assert :error = FlexibleItems.move(items, "c", "down")
      assert :error = FlexibleItems.move(items, "zzz", "down")
    end

    test "reorder wants exactly the ids the list holds", %{items: items} do
      assert {:ok, [%{"_id" => "c"}, %{"_id" => "a"}, %{"_id" => "b"}]} =
               FlexibleItems.reorder(items, ["c", "a", "b"])

      for bad <- [["a", "a", "b"], ["a", "b"], ["a", "b", "c", "d"], [0, 1, 2], "abc", nil] do
        assert :error = FlexibleItems.reorder(items, bad)
      end
    end

    test "duplicate re-mints every id in the copy and puts it after the original", %{items: items} do
      assert {:ok, [_, _, %{"_id" => "c"} = original, copy]} =
               FlexibleItems.duplicate(items, definition(), "c")

      assert copy["_id"] != "c"
      assert [%{"_id" => cell_id}] = copy["cells"]
      assert cell_id != "d"
      assert original["cells"] == [%{"_id" => "d", "_type" => "cell"}]
      assert :error = FlexibleItems.duplicate(items, definition(), "nope")
    end

    test "update_list reaches a nested list by its path, and refuses a path that is none", %{
      items: items
    } do
      assert {:ok, [_, _, %{"cells" => [%{"_id" => "d"}, %{"_type" => "cell"}]}]} =
               FlexibleItems.update_list(items, definition(), ["c", "cells"], fn cells, def ->
                 FlexibleItems.add(cells, def, "cell")
               end)

      for bad <- [["c", "nope"], ["zzz", "cells"], ["a", "cells"], ["c"]] do
        assert :error = FlexibleItems.update_list(items, definition(), bad, &{:ok, &1})
      end
    end
  end

  describe "pending/2" do
    defp pending(items),
      do: FlexibleItems.pending(%{"custom_fields" => %{"sections" => items}}, [definition()])

    test "a blank card, at any depth, is kept; a filled one is not" do
      assert pending([%{"_id" => "a", "_type" => "hero", "headline" => ""}]) != %{}
      assert pending([%{"_id" => "a", "_type" => "hero", "headline" => "x"}]) == %{}

      nested = [
        %{
          "_type" => "columns",
          "cells" => [
            %{"_type" => "cell", "label" => "", "notes" => [%{"_type" => "note", "text" => ""}]}
          ]
        }
      ]

      assert %{"sections" => ^nested} = pending(nested)
      assert pending([]) == %{}
      assert FlexibleItems.pending(%{}, [definition()]) == %{}
    end
  end

  describe "errors/3" do
    test "resolves posted positions to the ids of the cards they belong to" do
      items = [
        %{"_id" => "a", "_type" => "hero"},
        %{
          "_id" => "c",
          "_type" => "columns",
          "cells" => [
            %{"_id" => "d", "_type" => "cell", "notes" => [%{"_id" => "n", "_type" => "note"}]}
          ]
        }
      ]

      messages = [
        "Sections is required",
        "Headline (sections[0].headline) is required",
        "Theme (sections[0]._settings.theme) is not a choice",
        "Hero (sections[0]._type) is odd",
        "Label (sections[1].cells[0].label) is required",
        "Text (sections[1].cells[0].notes[0].text) is too long",
        "Notes (sections[1].cells[0].notes) needs at least 2 items",
        "Hero (sections[7].headline) is gone",
        "Sections (sections) needs at least 3 items"
      ]

      problems = FlexibleItems.errors(messages, definition(), items)

      assert problems.field == [
               "Sections is required",
               "Hero (sections[7].headline) is gone",
               "Sections (sections) needs at least 3 items"
             ]

      assert problems.items["sections/a"].cells == %{
               "headline" => ["Headline is required"],
               "theme" => ["Theme is not a choice"]
             }

      assert problems.items["sections/a"].item == ["is odd"]
      assert problems.items["sections/c/cells/d"].cells == %{"label" => ["Label is required"]}

      assert problems.items["sections/c/cells/d/notes/n"].cells == %{
               "text" => ["Text is too long"]
             }

      assert problems.lists == %{"sections/c/cells/d/notes" => ["needs at least 2 items"]}

      assert FlexibleItems.errors?(problems, "sections/c")
      assert FlexibleItems.errors?(problems, "sections/c/cells/d")
      assert FlexibleItems.errors?(problems, "sections/a")
      refute FlexibleItems.errors?(problems, "sections/b")
      # A prefix of an id is not the id.
      refute FlexibleItems.errors?(problems, "sections/")
    end
  end

  describe "summary/2 and bounds" do
    test "the first non-blank text content value, markup stripped and cut" do
      type = type("hero", [sub("empty"), sub("headline"), sub("theme", %{item_setting: true})])
      item = %{"empty" => " ", "headline" => "<p>Hello   <b>world</b></p>", "theme" => "dark"}
      assert FlexibleItems.summary(item, type) == "Hello world"

      assert FlexibleItems.summary(%{"headline" => String.duplicate("x", 200)}, type)
             |> String.length() == 80

      assert FlexibleItems.summary(%{"theme" => "dark"}, type) == nil
      assert FlexibleItems.summary(item, nil) == nil
    end

    test "full?/2 falls back to the default cap; at_minimum?/2 reads min_items" do
      refute FlexibleItems.full?(List.duplicate(%{}, 99), %{max_items: nil})
      assert FlexibleItems.full?(List.duplicate(%{}, 100), %{max_items: nil})
      assert FlexibleItems.full?([%{}], %{max_items: 1})
      assert FlexibleItems.at_minimum?([%{}], %{min_items: 1})
      refute FlexibleItems.at_minimum?([%{}], %{min_items: nil})
    end
  end

  describe "media and reference sub-fields (#2282)" do
    defp media_def do
      flexible("sections", [
        type("hero", [
          sub("headline"),
          sub("image", %{field_type: :media, multiple: false}),
          sub("link", %{field_type: :reference, multiple: false, target_type: "page"}),
          sub("either", %{
            field_type: :reference,
            multiple: false,
            target_types: ["page", "post"],
            item_setting: true
          }),
          sub("gallery", %{field_type: :media, multiple: true})
        ])
      ])
    end

    @items [%{"_id" => "a", "_type" => "hero", "headline" => "x"}]

    test "put_value/6 sets and clears one sub-field of the item it names" do
      assert {:ok, [%{"image" => "m1", "headline" => "x"}]} =
               FlexibleItems.put_value(@items, media_def(), "a", "image", :media, "m1")

      assert {:ok, [%{"image" => ""}]} =
               FlexibleItems.put_value(@items, media_def(), "a", "image", :media, "")
    end

    test "put_value/6 refuses an unknown item, sub-field, other type or a list sub-field" do
      for {id, sub, type} <- [
            {"gone", "image", :media},
            {"a", "nope", :media},
            {"a", "headline", :media},
            {"a", "image", :reference},
            {"a", "link", :media},
            {"a", "gallery", :media}
          ] do
        assert :error = FlexibleItems.put_value(@items, media_def(), id, sub, type, "m1")
      end
    end

    test "a reference that allows several types stores the picker's token as a map" do
      assert {:ok, [%{"_settings" => %{"either" => %{"type" => "post", "id" => "p1"}}}]} =
               FlexibleItems.put_value(@items, media_def(), "a", "either", :reference, "post:p1")

      assert {:ok, [%{"link" => "p1"}]} =
               FlexibleItems.put_value(@items, media_def(), "a", "link", :reference, "p1")
    end

    test "normalize/2 turns a posted token into the map the write needs" do
      params = %{
        "custom_fields" => %{
          "sections" => %{
            "0" => %{
              "_id" => "a",
              "_type" => "hero",
              "image" => "m1",
              "_settings" => %{"either" => "page:p1"}
            }
          }
        }
      }

      assert %{"custom_fields" => %{"sections" => [item]}} =
               FlexibleItems.normalize(params, [media_def()])

      assert item["image"] == "m1"
      assert item["_settings"]["either"] == %{"type" => "page", "id" => "p1"}
    end

    test "an id is never an item's summary" do
      type = hd(FlexibleItems.type(media_def(), %{"_type" => "hero"}) |> List.wrap())

      assert FlexibleItems.summary(
               %{"image" => "3f1c0b5a-0000-4000-8000-000000000000"},
               type
             ) == nil
    end
  end
end
