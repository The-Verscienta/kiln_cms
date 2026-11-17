defmodule KilnCMSWeb.FlexibleEditorTest do
  @moduledoc """
  A `:flexible` custom field in the content editor (#2282, PR 2): item cards
  (type badge, summary, move, duplicate, remove, collapse), an "Add item" menu
  that honors the field's and each type's `max_items`, settings that are
  always posted even while collapsed, nested flexible lists to the depth cap,
  orphan items as locked cards that are never posted back, errors shown on
  the card whose posted position they name, and events that address an item by
  its `_id`, so a stale page cannot move the wrong one.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  @hero "11111111-1111-4111-8111-111111111111"
  @quote "22222222-2222-4222-8222-222222222222"
  @columns "33333333-3333-4333-8333-333333333333"
  @cell "44444444-4444-4444-8444-444444444444"
  @note "55555555-5555-4555-8555-555555555555"

  defp authed_user(role, extra \\ %{}) do
    email = "fle-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp signed_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.put_new(attrs, :label, "Field"), actor: admin)

  defp item_type!(admin, flexible, name, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(
          %{
            name: name,
            label: String.capitalize(name),
            field_type: :group,
            flex_of_id: flexible.id
          },
          attrs
        )
      )

  defp sub!(admin, parent, name, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(
          %{
            name: name,
            label: String.capitalize(name),
            group_of_id: parent.id,
            field_type: :string
          },
          attrs
        )
      )

  setup %{conn: conn} do
    admin = authed_user(:admin)

    sections =
      def!(admin, %{
        content_type: :page,
        name: "sections",
        label: "Sections",
        field_type: :flexible,
        max_items: 5,
        position: 0
      })

    hero = item_type!(admin, sections, "hero", %{position: 0})
    quote_type = item_type!(admin, sections, "quote", %{position: 1, max_items: 2})
    columns = item_type!(admin, sections, "columns", %{position: 2})

    sub!(admin, hero, "headline", %{required: true})
    sub!(admin, hero, "size", %{field_type: :integer, position: 1})

    sub!(admin, hero, "background", %{
      field_type: :select,
      options: ["dark", "light"],
      item_setting: true,
      position: 2
    })

    sub!(admin, hero, "accent", %{item_setting: true, position: 3})

    sub!(admin, quote_type, "text")
    sub!(admin, quote_type, "cite", %{position: 1})

    cells = sub!(admin, columns, "cells", %{field_type: :flexible})
    cell = item_type!(admin, cells, "cell")
    sub!(admin, cell, "label", %{required: true})
    notes = sub!(admin, cell, "notes", %{field_type: :flexible, position: 1})
    note = item_type!(admin, notes, "note")
    sub!(admin, note, "text")

    page =
      CMS.create_page!(
        %{
          title: "Flexible",
          slug: "fle-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "sections" => [
              %{
                "_id" => @hero,
                "_type" => "hero",
                "headline" => "Welcome",
                "size" => 3,
                "_settings" => %{"background" => "dark", "accent" => "teal"}
              },
              %{"_id" => @quote, "_type" => "quote", "text" => "Be brief"},
              %{
                "_id" => @columns,
                "_type" => "columns",
                "cells" => [
                  %{
                    "_id" => @cell,
                    "_type" => "cell",
                    "label" => "left",
                    "notes" => [%{"_id" => @note, "_type" => "note", "text" => "deep"}]
                  }
                ]
              }
            ]
          }
        },
        actor: admin
      )

    {:ok, lv, _html} = conn |> signed_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    %{admin: admin, page: page, lv: lv, conn: conn, sections: sections}
  end

  defp card(id), do: "#cf-flex-sections-#{id}"
  defp list, do: "#custom-field-sections-items"

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields["sections"]

  defp order(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#custom-field-sections-items > li")
    |> Enum.map(&(&1 |> Floki.attribute("data-sort-id") |> List.first()))
  end

  defp add(lv, at, type), do: render_hook(lv, "flex_add", %{"at" => at, "type" => type})

  defp ids(order), do: Enum.filter(order, &Regex.match?(~r/\A[0-9a-f-]{36}\z/, &1))

  defp save(lv), do: lv |> form("#page-editor") |> render_submit()

  describe "the cards" do
    test "an item per card with its type, summary and controls; no read-only note", ctx do
      assert order(ctx.lv) == [@hero, @quote, @columns]

      hero = ctx.lv |> element(card(@hero)) |> render()
      assert hero =~ "Hero"
      assert hero =~ "Welcome"
      assert has_element?(ctx.lv, "#{card(@hero)} #{card(@hero)}-duplicate")
      assert has_element?(ctx.lv, "#{card(@hero)}-remove")
      assert has_element?(ctx.lv, "#{card(@hero)}-toggle[aria-expanded=true]")
      assert has_element?(ctx.lv, "#{card(@hero)}-up[disabled]")
      refute has_element?(ctx.lv, "#{card(@quote)}-up[disabled]")
      assert has_element?(ctx.lv, "#{card(@columns)}-down[disabled]")

      assert has_element?(
               ctx.lv,
               "#{list()}[phx-hook=Sortable][data-sort-event=flex_reorder][data-sort-field=sections]"
             )

      assert has_element?(ctx.lv, "#custom-field-sections", "3 of 5 items")
      refute render(ctx.lv) =~ "Edited through the API"

      # The wire form: id and type ride with the card, content under its position.
      assert has_element?(ctx.lv, ~s(input[name="form[custom_fields][sections][0][_id]"]))
      assert has_element?(ctx.lv, ~s(input[name="form[custom_fields][sections][0][_type]"]))

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-sections-#{@hero}-headline[name="form[custom_fields][sections][0][headline]"][value=Welcome])
             )
    end

    test "cards start expanded, with collapse kept by the client across patches", ctx do
      html = ctx.lv |> element(card(@hero)) |> render()
      assert html =~ ~s(data-collapsed="false")
      assert html =~ "ignore_attrs"
      assert html =~ "toggle_attr"

      # Collapse is a JS command, not a server round trip: nothing in the
      # toggle pushes an event.
      toggle = ctx.lv |> element("#{card(@hero)}-toggle") |> render()
      refute toggle =~ ~s("push")
    end

    test "every cell is posted from a collapsed card too: settings are always rendered", ctx do
      assert has_element?(
               ctx.lv,
               ~s(#{card(@hero)} .flex-settings[data-open=false] select[name="form[custom_fields][sections][0][_settings][background]"] option[value=dark][selected])
             )

      assert has_element?(
               ctx.lv,
               ~s(#{card(@hero)} input[name="form[custom_fields][sections][0][_settings][accent]"][value=teal])
             )

      # Required is left to the save, so a hidden input never blocks the form.
      refute render(ctx.lv) =~ ~r/name="form\[custom_fields\]\[sections\][^>]*required/
    end

    test "editing a card and saving keeps its settings and its id", ctx do
      ctx.lv
      |> form("#page-editor", %{
        "form" => %{"custom_fields" => %{"sections" => %{"0" => %{"headline" => "Hi"}}}}
      })
      |> render_change()

      save(ctx.lv)

      assert [
               %{
                 "_id" => @hero,
                 "headline" => "Hi",
                 "size" => 3,
                 "_settings" => %{"background" => "dark", "accent" => "teal"}
               },
               %{"_id" => @quote},
               %{"_id" => @columns}
             ] = stored(ctx)
    end

    test "a setting changed while its section is collapsed saves", ctx do
      ctx.lv
      |> form("#page-editor", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{"0" => %{"_settings" => %{"background" => "light"}}}
          }
        }
      })
      |> render_change()

      save(ctx.lv)
      assert [%{"_settings" => %{"background" => "light", "accent" => "teal"}} | _] = stored(ctx)
    end
  end

  describe "adding" do
    test "the menu lists the item types, and a click adds a blank card of that type", ctx do
      for type <- ~w(hero quote columns) do
        assert has_element?(ctx.lv, "#custom-field-sections-add-#{type}")
      end

      assert has_element?(ctx.lv, "#custom-field-sections-add[aria-expanded=false]")
      assert has_element?(ctx.lv, "#custom-field-sections-add-menu[hidden]")

      ctx.lv |> element("#custom-field-sections-add-hero") |> render_click()
      assert [@hero, @quote, @columns, new] = order(ctx.lv)
      assert {:ok, _} = Ecto.UUID.cast(new)
      assert has_element?(ctx.lv, "#cf-flex-sections-#{new}", "Hero")

      assert has_element?(
               ctx.lv,
               ~s(input[name="form[custom_fields][sections][3][_type]"][value=hero])
             )
    end

    test "a field at max_items disables Add and refuses a forged add", ctx do
      add(ctx.lv, "sections", "hero")
      add(ctx.lv, "sections", "hero")
      assert length(order(ctx.lv)) == 5
      assert has_element?(ctx.lv, "#custom-field-sections-add[disabled]")
      assert render(ctx.lv) =~ "That&#39;s the most this field holds."

      add(ctx.lv, "sections", "hero")
      assert length(order(ctx.lv)) == 5
    end

    test "a type at its own max_items is disabled in the menu and refused", ctx do
      add(ctx.lv, "sections", "quote")
      assert length(order(ctx.lv)) == 4
      assert has_element?(ctx.lv, "#custom-field-sections-add-quote[disabled]")
      refute has_element?(ctx.lv, "#custom-field-sections-add-hero[disabled]")

      add(ctx.lv, "sections", "quote")
      assert length(order(ctx.lv)) == 4
    end

    test "an unknown type or address adds nothing", ctx do
      add(ctx.lv, "sections", "ghost")
      add(ctx.lv, "ghost", "hero")
      add(ctx.lv, "sections/#{@hero}/nope", "hero")
      assert order(ctx.lv) == [@hero, @quote, @columns]
    end
  end

  describe "remove, move, reorder, duplicate" do
    test "remove takes one card by its id", ctx do
      ctx.lv |> element("#{card(@quote)}-remove") |> render_click()
      assert order(ctx.lv) == [@hero, @columns]
      save(ctx.lv)
      assert [%{"_id" => @hero}, %{"_id" => @columns}] = stored(ctx)
    end

    test "removing every card clears the field", ctx do
      for id <- [@hero, @quote, @columns],
          do: ctx.lv |> element("#{card(id)}-remove") |> render_click()

      assert has_element?(ctx.lv, "#custom-field-sections", "No items yet.")
      save(ctx.lv)
      refute Map.has_key?(CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields, "sections")
    end

    test "the arrows swap neighbours and the order saves", ctx do
      ctx.lv |> element("#{card(@quote)}-up") |> render_click()
      assert order(ctx.lv) == [@quote, @hero, @columns]
      ctx.lv |> element("#{card(@quote)}-down") |> render_click()
      ctx.lv |> element("#{card(@hero)}-down") |> render_click()
      assert order(ctx.lv) == [@quote, @hero, @columns]
      ctx.lv |> element("#{card(@columns)}-up") |> render_click()
      assert order(ctx.lv) == [@quote, @columns, @hero]

      save(ctx.lv)
      assert [%{"_id" => @quote}, %{"_id" => @columns}, %{"_id" => @hero}] = stored(ctx)
    end

    test "a dragged order is a permutation of the ids, or nothing", ctx do
      render_hook(ctx.lv, "flex_reorder", %{
        "field" => "sections",
        "order" => [@columns, @hero, @quote]
      })

      assert order(ctx.lv) == [@columns, @hero, @quote]

      for bad <- [
            [@hero, @hero, @quote],
            [@hero, @quote],
            [@columns, @hero, @quote, @cell],
            ["0", "1", "2"]
          ] do
        render_hook(ctx.lv, "flex_reorder", %{"field" => "sections", "order" => bad})
        assert order(ctx.lv) == [@columns, @hero, @quote]
      end
    end

    test "the typed values follow their card through a reorder", ctx do
      render_hook(ctx.lv, "flex_reorder", %{
        "field" => "sections",
        "order" => [@quote, @columns, @hero]
      })

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-sections-#{@hero}-headline[name="form[custom_fields][sections][2][headline]"][value=Welcome])
             )
    end

    test "a stale event acts on the item it names, not the position it had", ctx do
      # The page showed [hero, quote, columns]; another reorder landed first.
      render_hook(ctx.lv, "flex_reorder", %{
        "field" => "sections",
        "order" => [@columns, @hero, @quote]
      })

      # "Move the quote up", sent by the stale page, moves the quote — now last.
      ctx.lv |> render_hook("flex_move", %{"at" => "sections/#{@quote}", "dir" => "up"})
      assert order(ctx.lv) == [@columns, @quote, @hero]

      # An id that is gone (removed elsewhere) is a no-op, never another card.
      render_hook(ctx.lv, "flex_remove", %{"at" => "sections/#{Ecto.UUID.generate()}"})
      assert order(ctx.lv) == [@columns, @quote, @hero]

      # A move past the end is a no-op too.
      render_hook(ctx.lv, "flex_move", %{"at" => "sections/#{@hero}", "dir" => "down"})
      assert order(ctx.lv) == [@columns, @quote, @hero]
    end

    test "duplicate copies the card after itself with new ids, nested ones too", ctx do
      ctx.lv |> element("#{card(@columns)}-duplicate") |> render_click()
      assert [@hero, @quote, @columns, copy] = order(ctx.lv)
      assert copy != @columns

      save(ctx.lv)

      assert [_, _, original, duplicate] = stored(ctx)
      assert original["_id"] == @columns
      assert duplicate["_id"] == copy
      [%{"_id" => cell_a, "notes" => [%{"_id" => note_a}]}] = original["cells"]
      [%{"_id" => cell_b, "notes" => [%{"_id" => note_b, "text" => "deep"}]}] = duplicate["cells"]
      assert cell_a == @cell and note_a == @note
      assert Enum.uniq([cell_a, cell_b]) |> length() == 2
      assert Enum.uniq([note_a, note_b]) |> length() == 2
    end

    test "duplicate respects the field's and the type's max_items", ctx do
      add(ctx.lv, "sections", "quote")
      # quote is at its type max (2): its duplicate button is off, and so is a forged one.
      assert has_element?(ctx.lv, "#{card(@quote)}-duplicate[disabled]")
      render_hook(ctx.lv, "flex_duplicate", %{"at" => "sections/#{@quote}"})
      assert length(order(ctx.lv)) == 4

      render_hook(ctx.lv, "flex_duplicate", %{"at" => "sections/#{@hero}"})
      assert length(order(ctx.lv)) == 5
      render_hook(ctx.lv, "flex_duplicate", %{"at" => "sections/#{@hero}"})
      assert length(order(ctx.lv)) == 5
    end
  end

  describe "nested flexible lists" do
    test "render as lists of their own down to the depth cap, keyed by the id chain", ctx do
      cell = "#{card(@columns)}-cells-#{@cell}"
      note = "#{cell}-notes-#{@note}"

      assert has_element?(ctx.lv, cell, "left")
      assert has_element?(ctx.lv, note, "deep")

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-sections-#{@columns}-cells-items[phx-hook=Sortable][data-sort-field="sections/#{@columns}/cells"])
             )

      # Each list's handles are its own: a drag in the inner one never starts the outer.
      assert has_element?(
               ctx.lv,
               ~s(#{cell} > div button[data-flex-handle="custom-field-sections-#{@columns}-cells"])
             )

      refute has_element?(
               ctx.lv,
               ~s(#{cell} > div button[data-flex-handle="custom-field-sections"])
             )

      assert has_element?(
               ctx.lv,
               ~s(input[name="form[custom_fields][sections][2][cells][0][notes][0][text]"][value=deep])
             )
    end

    test "add, move and remove address the nested list by its path", ctx do
      at = "sections/#{@columns}/cells/#{@cell}/notes"
      add(ctx.lv, at, "note")

      assert has_element?(
               ctx.lv,
               "#custom-field-sections-#{@columns}-cells-#{@cell}-notes-items > li",
               "Note"
             )

      assert has_element?(
               ctx.lv,
               ~s(input[name="form[custom_fields][sections][2][cells][0][notes][1][_type]"])
             )

      ctx.lv
      |> form("#page-editor", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{
              "2" => %{"cells" => %{"0" => %{"notes" => %{"1" => %{"text" => "second"}}}}}
            }
          }
        }
      })
      |> render_change()

      render_hook(ctx.lv, "flex_move", %{"at" => "#{at}/#{@note}", "dir" => "down"})
      save(ctx.lv)

      assert [_, _, %{"cells" => [%{"notes" => [%{"text" => "second"}, %{"_id" => @note}]}]}] =
               stored(ctx)

      render_hook(ctx.lv, "flex_remove", %{"at" => "#{at}/#{@note}"})
      save(ctx.lv)
      assert [_, _, %{"cells" => [%{"notes" => [%{"text" => "second"}]}]}] = stored(ctx)
    end

    test "a drag of the inner list reorders it and leaves the outer list alone", ctx do
      at = "sections/#{@columns}/cells"
      add(ctx.lv, at, "cell")
      assert [_, new] = nested_ids(ctx.lv, "custom-field-sections-#{@columns}-cells-items")

      render_hook(ctx.lv, "flex_reorder", %{"field" => at, "order" => [new, @cell]})
      assert nested_ids(ctx.lv, "custom-field-sections-#{@columns}-cells-items") == [new, @cell]
      assert order(ctx.lv) == [@hero, @quote, @columns]
    end

    test "an edit in the nested list reaches the saved value", ctx do
      ctx.lv
      |> form("#page-editor", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{"2" => %{"cells" => %{"0" => %{"label" => "right"}}}}
          }
        }
      })
      |> render_change()

      save(ctx.lv)
      assert [_, _, %{"cells" => [%{"_id" => @cell, "label" => "right"}]}] = stored(ctx)
    end
  end

  defp nested_ids(lv, list_id) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("##{list_id} > li")
    |> Enum.map(&(&1 |> Floki.attribute("data-sort-id") |> List.first()))
  end

  describe "autosave" do
    test "keeps a blank card just added on screen, and saves nothing for it", ctx do
      add(ctx.lv, "sections", "quote")
      new = ctx.lv |> order() |> List.last()
      send(ctx.lv.pid, :autosave)
      _ = render(ctx.lv)

      assert has_element?(ctx.lv, "#cf-flex-sections-#{new}")
      assert [_, _, _] = stored(ctx)
    end

    test "keeps a blank nested card too", ctx do
      add(ctx.lv, "sections/#{@columns}/cells", "cell")
      send(ctx.lv.pid, :autosave)
      _ = render(ctx.lv)

      assert [_, _] = nested_ids(ctx.lv, "custom-field-sections-#{@columns}-cells-items") |> ids()
      assert [_, _, %{"cells" => [_]}] = stored(ctx)
    end
  end

  describe "orphan items" do
    setup ctx do
      orphan = "66666666-6666-4666-8666-666666666666"

      KilnCMS.Repo.query!(
        "UPDATE pages SET custom_fields = jsonb_set(custom_fields, '{sections}', custom_fields->'sections' || $1::jsonb) WHERE id = $2",
        [
          [%{"_id" => orphan, "_type" => "ghost", "headline" => "Secret"}],
          Ecto.UUID.dump!(ctx.page.id)
        ]
      )

      {:ok, lv, _html} =
        ctx.conn |> signed_in(ctx.admin) |> live(~p"/editor/content/page/#{ctx.page.id}")

      %{lv: lv, orphan: orphan}
    end

    test "is a locked card: Remove only, no inputs for its content", ctx do
      assert has_element?(ctx.lv, card(ctx.orphan), "no longer exists")
      assert has_element?(ctx.lv, "#{card(ctx.orphan)}-remove")
      refute has_element?(ctx.lv, "#{card(ctx.orphan)}-up")
      refute has_element?(ctx.lv, "#{card(ctx.orphan)}-duplicate")
      refute has_element?(ctx.lv, "#{card(ctx.orphan)}-toggle")
      refute has_element?(ctx.lv, "#{card(ctx.orphan)} input:not([type=hidden])")
      refute render(ctx.lv) =~ "Secret"
    end

    test "is never posted back: the card stays until saved, then it is gone", ctx do
      ctx.lv
      |> form("#page-editor", %{
        "form" => %{"custom_fields" => %{"sections" => %{"0" => %{"headline" => "Hi"}}}}
      })
      |> render_change()

      # Still on screen after an edit (its id and type ride as inert markers) …
      assert has_element?(ctx.lv, card(ctx.orphan))

      save(ctx.lv)
      # … and the save keeps the rest and drops it.
      assert [%{"_id" => @hero, "headline" => "Hi"}, %{"_id" => @quote}, %{"_id" => @columns}] =
               stored(ctx)
    end

    test "Remove takes it off the screen", ctx do
      ctx.lv |> element("#{card(ctx.orphan)}-remove") |> render_click()
      refute has_element?(ctx.lv, card(ctx.orphan))
    end
  end

  describe "problems" do
    test "show on the card their posted position names, and open it", ctx do
      # A blank hero first (a save drops it), then one with a bad number: the
      # path says position 4, which is the second one — not 3, where a count
      # after the blank drop would put it.
      add(ctx.lv, "sections", "hero")
      add(ctx.lv, "sections", "hero")
      [_, _, _, blank, bad] = order(ctx.lv)

      ctx.lv
      |> form("#page-editor", %{
        "form" => %{"custom_fields" => %{"sections" => %{"4" => %{"size" => "lots"}}}}
      })
      |> render_change()

      save(ctx.lv)

      assert has_element?(ctx.lv, "#{card(bad)}[data-errors=true]")
      assert has_element?(ctx.lv, "#{card(bad)}", "Size must be a whole number")
      assert has_element?(ctx.lv, "#{card(bad)}", "Headline is required")
      assert has_element?(ctx.lv, "#{card(bad)} #{card(bad)}-toggle .text-error")
      assert has_element?(ctx.lv, "#{card(blank)}[data-errors=false]")
      assert has_element?(ctx.lv, ~s(#custom-field-sections-#{bad}-size[aria-invalid="true"]))
      assert [_, _, _] = stored(ctx)
    end

    test "a problem in a nested item opens every card above it", ctx do
      cells = "sections/#{@columns}/cells"
      add(ctx.lv, cells, "cell")
      [_, new_cell] = nested_ids(ctx.lv, "custom-field-sections-#{@columns}-cells-items")
      add(ctx.lv, "#{cells}/#{new_cell}/notes", "note")
      assert has_element?(ctx.lv, "#{card(@columns)}[data-errors=false]")

      ctx.lv
      |> form("#page-editor", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{
              "2" => %{"cells" => %{"1" => %{"notes" => %{"0" => %{"text" => "x"}}}}}
            }
          }
        }
      })
      |> render_change()

      save(ctx.lv)

      # The new cell is not blank (its note has text) and has no label.
      assert has_element?(ctx.lv, "#{card(@columns)}[data-errors=true]")
      assert has_element?(ctx.lv, "#{card(@columns)}-cells-#{new_cell}[data-errors=true]")
      assert has_element?(ctx.lv, "#{card(@columns)}-cells-#{@cell}[data-errors=false]")
      assert has_element?(ctx.lv, "#{card(@columns)}-cells-#{new_cell}", "Label is required")
      assert has_element?(ctx.lv, "#{card(@hero)}[data-errors=false]")
      assert [_, _, %{"cells" => [%{"_id" => @cell}]}] = stored(ctx)
    end

    test "a settings problem opens the Settings section", ctx do
      ctx.lv
      |> form("#page-editor", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{"0" => %{"_settings" => %{"background" => "light"}}}
          }
        }
      })
      |> render_change()

      render_hook(ctx.lv, "save", %{
        "form" => %{
          "custom_fields" => %{
            "sections" => %{
              "0" => %{
                "_id" => @hero,
                "_type" => "hero",
                "headline" => "x",
                "_settings" => %{"background" => "purple"}
              }
            }
          }
        }
      })

      assert has_element?(ctx.lv, "#{card(@hero)}-settings[data-errors=true]")
    end
  end

  describe "a field the editor's write grant leaves out" do
    setup ctx do
      editor = authed_user(:editor, %{field_grants: %{"page" => ["title"]}})

      {:ok, lv, _html} =
        ctx.conn
        |> recycle()
        |> signed_in(editor)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      %{lv: lv}
    end

    test "renders read-only, and every flexible event changes nothing", ctx do
      assert has_element?(ctx.lv, "#cf-read-only-sections")
      assert has_element?(ctx.lv, "fieldset[disabled] #custom-field-sections")

      add(ctx.lv, "sections", "hero")
      render_hook(ctx.lv, "flex_remove", %{"at" => "sections/#{@hero}"})
      render_hook(ctx.lv, "flex_move", %{"at" => "sections/#{@hero}", "dir" => "down"})
      render_hook(ctx.lv, "flex_duplicate", %{"at" => "sections/#{@hero}"})

      render_hook(ctx.lv, "flex_reorder", %{
        "field" => "sections",
        "order" => [@columns, @quote, @hero]
      })

      assert order(ctx.lv) == [@hero, @quote, @columns]
    end

    test "a granted editor edits it", ctx do
      editor =
        authed_user(:editor, %{field_grants: %{"page" => ["title", "custom_fields.sections"]}})

      {:ok, lv, _html} =
        ctx.conn
        |> recycle()
        |> signed_in(editor)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      refute has_element?(lv, "#cf-read-only-sections")
      add(lv, "sections", "quote")
      assert length(order(lv)) == 4
    end
  end
end
