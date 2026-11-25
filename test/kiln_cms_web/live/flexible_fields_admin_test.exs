defmodule KilnCMSWeb.FlexibleFieldsAdminTest do
  @moduledoc """
  The fields admin (`/editor/fields`) for a `:flexible` field (#2282, PR 2):
  the type picker offers it, an "Item types" panel inside the field adds, edits,
  reorders and deletes item types, each with its own "Fields in each item" (a
  "Setting" flag per sub-field, flexible sub-fields nesting to the depth cap),
  deleting an item type or a flexible field counts the stored items and asks
  again if the number moved, renaming an item type keeps its items, and a field
  is never retyped to or from `:flexible`.
  """
  use KilnCMSWeb.ConnCase, async: true

  # The cross-site test creates a second organization, which logs a warning.
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed(role) do
    email = "flexa-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp item_type!(admin, flexible, name),
    do:
      def!(admin, %{
        name: name,
        label: String.capitalize(String.replace_prefix(name, "ffa_", "")),
        field_type: :group,
        flex_of_id: flexible.id
      })

  defp sub!(admin, parent, name, attrs \\ %{}),
    do:
      def!(
        admin,
        Map.merge(
          %{
            name: name,
            label: String.capitalize(String.replace_prefix(name, "ffa_", "")),
            group_of_id: parent.id,
            field_type: :string
          },
          attrs
        )
      )

  defp raw_sections(post) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT custom_fields FROM posts WHERE id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

    value["ffa_sections"]
  end

  defp open(conn, admin) do
    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    {lv, html}
  end

  setup do
    admin = authed(:admin)

    sections =
      def!(admin, %{
        content_type: :post,
        name: "ffa_sections",
        label: "Sections",
        field_type: :flexible
      })

    %{admin: admin, sections: sections}
  end

  describe "the field itself" do
    test "the new-field picker offers flexible content, and defining one explains it", %{
      conn: conn,
      admin: admin
    } do
      {lv, _html} = open(conn, admin)

      assert has_element?(lv, "#new-field-form select option[value=flexible]", "Flexible content")

      html =
        lv
        |> form("#new-field-form", field_definition: %{field_type: "flexible", scopes: ["page"]})
        |> render_change()

      assert html =~ "data with settings, not page layout"
      assert has_element?(lv, "#new-field-multiple-bounds")
      assert has_element?(lv, "#new-field-multiple-item-types-hint")
      assert has_element?(lv, "#new-field-form input[name='field_definition[searchable]']")
      refute has_element?(lv, "#new-field-form input[name='field_definition[names_record]']")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          label: "Blocks",
          name: "blocks",
          field_type: "flexible",
          min_items: "1",
          max_items: "5"
        }
      )
      |> render_submit()

      field =
        :page |> CMS.field_definitions_for!(actor: admin) |> Enum.find(&(&1.name == "blocks"))

      assert %{field_type: :flexible, multiple: true, min_items: 1, max_items: 5} = field
      assert has_element?(lv, "#field-#{field.id}-item-bounds", "Between 1 and 5 items")
      assert has_element?(lv, "#field-#{field.id}-item-types-add")
      assert has_element?(lv, "#field-#{field.id}-item-types", "No item types yet")
    end

    test "lists its item types and their sub-fields under it, not as fields of a type", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      sub!(admin, hero, "headline")
      {lv, html} = open(conn, admin)

      assert has_element?(lv, "#field-#{sections.id}-item-types #item-type-#{hero.id}", "Hero")
      assert has_element?(lv, "#field-#{hero.id}-sub-fields", "Fields in each item")
      assert html =~ "headline"
      # a type's own list holds only its fields
      refute has_element?(lv, "#fields-type-post > li#field-#{hero.id}")
    end

    test "the edit form leaves flexible out of every other field and locks its own", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      plain = def!(admin, %{content_type: :post, name: "ffa_plain", field_type: :string})
      {lv, _html} = open(conn, admin)

      lv |> element("button[phx-click=edit][phx-value-id='#{plain.id}']") |> render_click()
      refute has_element?(lv, "#edit-field-#{plain.id} select option[value=flexible]")

      lv |> element("button[phx-click=cancel_edit]") |> render_click()
      lv |> element("button[phx-click=edit][phx-value-id='#{sections.id}']") |> render_click()

      assert has_element?(
               lv,
               "#edit-field-#{sections.id} select[name='field_definition[field_type]'][disabled]"
             )

      assert has_element?(
               lv,
               "#edit-field-#{sections.id} input[type=hidden][name='field_definition[field_type]'][value=flexible]"
             )
    end

    test "a field cannot be retyped to or from flexible, even by a hand-made save", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      plain = def!(admin, %{content_type: :post, name: "ffa_plain", field_type: :string})
      {lv, _html} = open(conn, admin)

      lv |> element("button[phx-click=edit][phx-value-id='#{plain.id}']") |> render_click()

      html =
        render_submit(lv, "save_edit", %{"field_definition" => %{"field_type" => "flexible"}})

      assert html =~ "to or from a flexible field"
      assert CMS.get_field_definition!(plain.id, actor: admin).field_type == :string

      lv |> element("button[phx-click=cancel_edit]") |> render_click()
      lv |> element("button[phx-click=edit][phx-value-id='#{sections.id}']") |> render_click()

      html = render_submit(lv, "save_edit", %{"field_definition" => %{"field_type" => "string"}})

      assert html =~ "to or from a flexible field"
      assert CMS.get_field_definition!(sections.id, actor: admin).field_type == :flexible
    end

    test "editing a flexible field's bounds works", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("button[phx-click=edit][phx-value-id='#{sections.id}']") |> render_click()

      lv
      |> form("#edit-field-#{sections.id}", field_definition: %{max_items: "7"})
      |> render_submit()

      assert %{max_items: 7, field_type: :flexible} =
               CMS.get_field_definition!(sections.id, actor: admin)
    end
  end

  describe "item types" do
    test "an admin adds an item type, naming it from its label", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("#field-#{sections.id}-item-types-add") |> render_click()
      form_id = "#item-type-form-new-#{sections.id}"

      lv |> form(form_id, item_type: %{label: "Feature grid"}) |> render_change()
      assert has_element?(lv, "#{form_id} input[name='item_type[name]'][value=feature_grid]")

      lv
      |> form(form_id, item_type: %{max_items: "3", help_text: "A row of features"})
      |> render_submit()

      assert [item] =
               CMS.get_field_definition!(sections.id, actor: admin, load: :item_types).item_types

      assert %{name: "feature_grid", label: "Feature grid", max_items: 3, field_type: :group} =
               item

      assert item.flex_of_id == sections.id
      assert has_element?(lv, "#item-type-#{item.id}", "Feature grid")
      assert has_element?(lv, "#item-type-#{item.id}-max", "at most 3")
      assert has_element?(lv, "#field-#{item.id}-sub-fields", "No fields yet")
    end

    test "a name already used in the same field is refused", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      item_type!(admin, sections, "hero")
      {lv, _html} = open(conn, admin)
      lv |> element("#field-#{sections.id}-item-types-add") |> render_click()

      html =
        lv
        |> form("#item-type-form-new-#{sections.id}",
          item_type: %{label: "Hero again", name: "hero"}
        )
        |> render_submit()

      assert html =~ "is already an item type of this field"

      assert length(
               CMS.get_field_definition!(sections.id, actor: admin, load: :item_types).item_types
             ) == 1
    end

    test "an admin edits an item type, and renaming it keeps the items already stored", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      sub!(admin, hero, "headline")

      post =
        CMS.create_post!(
          %{
            title: "P",
            slug: "flexa-#{System.unique_integer([:positive])}",
            custom_fields: %{"ffa_sections" => [%{"_type" => "hero", "headline" => "A"}]}
          },
          actor: admin
        )

      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{hero.id}-edit") |> render_click()

      assert has_element?(
               lv,
               "#item-type-form-#{hero.id}",
               "keeps the items editors already added"
             )

      lv
      |> form("#item-type-form-#{hero.id}", item_type: %{name: "banner", label: "Banner"})
      |> render_submit()

      assert [%{"_type" => "banner", "headline" => "A"}] = raw_sections(post)
      assert has_element?(lv, "#item-type-#{hero.id}", "Banner")
    end

    test "arrows reorder item types", %{conn: conn, admin: admin, sections: sections} do
      a = item_type!(admin, sections, "aaa")

      b =
        def!(admin, %{
          name: "bbb",
          label: "Bbb",
          field_type: :group,
          flex_of_id: sections.id,
          position: 1
        })

      {lv, _html} = open(conn, admin)

      lv
      |> element("button[phx-click=item_type_move][phx-value-id='#{b.id}'][phx-value-dir=up]")
      |> render_click()

      assert CMS.get_field_definition!(b.id, actor: admin).position == 0
      assert CMS.get_field_definition!(a.id, actor: admin).position == 1
    end
  end

  describe "fields in each item" do
    test "a sub-field is added, content or setting, and a setting is fixed afterwards", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      {lv, _html} = open(conn, admin)

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()
      form_id = "#link-field-form-new-#{hero.id}"
      assert has_element?(lv, "#{form_id}-setting")

      lv
      |> form(form_id, link_field: %{label: "Headline", field_type: "string"})
      |> render_submit()

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()

      lv
      |> form(form_id, link_field: %{label: "Tone", field_type: "string", item_setting: "true"})
      |> render_submit()

      subs = CMS.get_field_definition!(hero.id, actor: admin, load: :group_fields).group_fields
      assert %{item_setting: false} = Enum.find(subs, &(&1.name == "headline"))
      tone = Enum.find(subs, &(&1.name == "tone"))
      assert tone.item_setting
      assert has_element?(lv, "#link-field-#{tone.id}-setting", "setting")

      lv |> element("#link-field-#{tone.id} button[phx-click=link_edit]") |> render_click()

      assert has_element?(
               lv,
               "#link-field-form-#{tone.id}-setting input[type=checkbox][disabled]"
             )
    end

    test "a sub-field may be an image, or a link to one record of the types ticked", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      {lv, _html} = open(conn, admin)
      form_id = "#link-field-form-new-#{hero.id}"

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()
      # The target choice appears for a reference only, with no cap, delete
      # rule or reverse-side control.
      refute has_element?(lv, "#{form_id}-targets")

      lv
      |> form(form_id, link_field: %{label: "Picture", field_type: "media"})
      |> render_submit()

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()

      lv
      |> form(form_id, link_field: %{label: "Link", field_type: "reference"})
      |> render_change()

      assert has_element?(lv, "#{form_id}-targets")
      refute has_element?(lv, "#{form_id} [name*=max_sources]")
      refute has_element?(lv, "#{form_id} [name*=on_target_delete]")
      refute has_element?(lv, "#{form_id} [name*=inverse]")
      refute has_element?(lv, "#{form_id} [name*=multiple]")

      # No type ticked: refused, with the same message a top-level field gets.
      html =
        lv
        |> form(form_id, link_field: %{label: "Link", field_type: "reference"})
        |> render_submit()

      assert html =~ "pick the type of content this field links to"

      lv
      |> form(form_id,
        link_field: %{label: "Link", field_type: "reference", target_types: ["", "page"]}
      )
      |> render_submit()

      subs = CMS.get_field_definition!(hero.id, actor: admin, load: :group_fields).group_fields
      assert %{field_type: :media, multiple: false} = Enum.find(subs, &(&1.name == "picture"))

      assert %{field_type: :reference, target_type: "page", target_types: [], multiple: false} =
               Enum.find(subs, &(&1.name == "link"))
    end

    test "a sub-field condition sees the item's content and settings", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      sub!(admin, hero, "headline")
      sub!(admin, hero, "tone", %{item_setting: true, position: 1})
      {lv, _html} = open(conn, admin)

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()

      lv
      |> element(
        "#link-field-form-new-#{hero.id} button[phx-click=cond_add][phx-value-rule=visible_when]"
      )
      |> render_click()

      html = render(lv)
      assert html =~ "Headline"
      assert html =~ "Tone"
    end

    test "a sub-field may be a flexible field with item types of its own, to the depth cap", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      hero = item_type!(admin, sections, "hero")
      {lv, _html} = open(conn, admin)

      lv |> element("#field-#{hero.id}-sub-fields-add") |> render_click()
      form_id = "#link-field-form-new-#{hero.id}"
      assert has_element?(lv, "#{form_id} select option[value=flexible]")

      lv
      |> form(form_id, link_field: %{label: "Rows", field_type: "flexible"})
      |> render_submit()

      rows =
        CMS.get_field_definition!(hero.id, actor: admin, load: :group_fields).group_fields |> hd()

      assert %{field_type: :flexible, name: "rows", group_of_id: group_id} = rows
      assert group_id == hero.id
      assert has_element?(lv, "#field-#{rows.id}-item-types-add")

      # level 2 -> its item type's sub-fields may nest once more (level 3), then not
      lv |> element("#field-#{rows.id}-item-types-add") |> render_click()
      lv |> form("#item-type-form-new-#{rows.id}", item_type: %{label: "Row"}) |> render_submit()
      row = CMS.get_field_definition!(rows.id, actor: admin, load: :item_types).item_types |> hd()

      lv |> element("#field-#{row.id}-sub-fields-add") |> render_click()
      assert has_element?(lv, "#link-field-form-new-#{row.id} select option[value=flexible]")

      lv
      |> form("#link-field-form-new-#{row.id}",
        link_field: %{label: "Cells", field_type: "flexible"}
      )
      |> render_submit()

      cells =
        CMS.get_field_definition!(row.id, actor: admin, load: :group_fields).group_fields |> hd()

      lv |> element("#field-#{cells.id}-item-types-add") |> render_click()

      lv
      |> form("#item-type-form-new-#{cells.id}", item_type: %{label: "Cell"})
      |> render_submit()

      cell =
        CMS.get_field_definition!(cells.id, actor: admin, load: :item_types).item_types |> hd()

      lv |> element("#field-#{cell.id}-sub-fields-add") |> render_click()
      refute has_element?(lv, "#link-field-form-new-#{cell.id} select option[value=flexible]")
      assert has_element?(lv, "#link-field-form-new-#{cell.id} select option[value=string]")
    end
  end

  describe "deleting" do
    setup %{admin: admin, sections: sections} do
      hero = item_type!(admin, sections, "hero")
      sub!(admin, hero, "headline")
      quote_type = item_type!(admin, sections, "quote")
      sub!(admin, quote_type, "text")

      post =
        CMS.create_post!(
          %{
            title: "P",
            slug: "flexa-#{System.unique_integer([:positive])}",
            custom_fields: %{
              "ffa_sections" => [
                %{"_type" => "hero", "headline" => "A"},
                %{"_type" => "hero", "headline" => "B"},
                %{"_type" => "quote", "text" => "Q"}
              ]
            }
          },
          actor: admin
        )

      %{hero: hero, quote_type: quote_type, post: post}
    end

    test "an item type shows how many items go with it, then purges them on confirm", %{
      conn: conn,
      admin: admin,
      hero: hero,
      post: post
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{hero.id}-delete") |> render_click()

      assert has_element?(lv, "#item-delete-#{hero.id}-count[data-count='2']", "2 stored items")
      # nothing is deleted by asking
      assert CMS.get_field_definition!(hero.id, actor: admin)

      lv |> element("#item-delete-#{hero.id}-confirm") |> render_click()

      assert {:error, _} = CMS.get_field_definition(hero.id, actor: admin)
      assert [%{"_type" => "quote"}] = raw_sections(post)
      refute has_element?(lv, "#item-type-#{hero.id}")
    end

    test "cancelling deletes nothing", %{conn: conn, admin: admin, hero: hero, post: post} do
      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{hero.id}-delete") |> render_click()
      lv |> element("#item-delete-#{hero.id}-cancel") |> render_click()

      refute has_element?(lv, "#item-delete-#{hero.id}")
      assert length(raw_sections(post)) == 3
    end

    test "an item type no item uses says so and goes without a purge", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      unused = item_type!(admin, sections, "unused")
      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{unused.id}-delete") |> render_click()

      assert has_element?(lv, "#item-delete-#{unused.id}-count", "No stored items")
      lv |> element("#item-delete-#{unused.id}-confirm") |> render_click()
      assert {:error, _} = CMS.get_field_definition(unused.id, actor: admin)
    end

    test "a confirm that finds the count moved shows the new count and deletes nothing", %{
      conn: conn,
      admin: admin,
      hero: hero,
      post: post
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{hero.id}-delete") |> render_click()
      assert has_element?(lv, "#item-delete-#{hero.id}-count[data-count='2']")

      # an editor saves another hero between the count and the click
      CMS.update_post!(
        post,
        %{
          custom_fields: %{
            "ffa_sections" => [
              %{"_type" => "hero", "headline" => "A"},
              %{"_type" => "hero", "headline" => "B"},
              %{"_type" => "hero", "headline" => "C"},
              %{"_type" => "quote", "text" => "Q"}
            ]
          }
        },
        actor: admin
      )

      lv |> element("#item-delete-#{hero.id}-confirm") |> render_click()

      assert has_element?(lv, "#item-delete-#{hero.id}-count[data-count='3']", "3 stored items")
      assert has_element?(lv, "#item-delete-#{hero.id}-changed")
      assert CMS.get_field_definition!(hero.id, actor: admin)
      assert length(raw_sections(post)) == 4

      # confirming the number just shown deletes
      lv |> element("#item-delete-#{hero.id}-confirm") |> render_click()
      assert [%{"_type" => "quote"}] = raw_sections(post)
    end

    test "a confirm for something that was not asked about does nothing", %{
      conn: conn,
      admin: admin,
      hero: hero,
      quote_type: quote_type,
      post: post
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("#item-type-#{hero.id}-delete") |> render_click()

      # a hand-made confirm naming another item type, and a stale one with no pending delete
      render_click(lv, "item_delete_confirm", %{"id" => quote_type.id})
      render_click(lv, "item_delete_cancel", %{})
      render_click(lv, "item_delete_confirm", %{"id" => hero.id})

      assert CMS.get_field_definition!(quote_type.id, actor: admin)
      assert CMS.get_field_definition!(hero.id, actor: admin)
      assert length(raw_sections(post)) == 3
    end

    test "a client cannot ask for the purge: the flag is decided from the count", %{
      conn: conn,
      admin: admin,
      hero: hero,
      post: post
    } do
      {lv, _html} = open(conn, admin)
      # no delete was asked about, so even a `purge_items?` param does nothing
      render_click(lv, "item_delete_confirm", %{"id" => hero.id, "purge_items?" => true})
      assert CMS.get_field_definition!(hero.id, actor: admin)
      assert length(raw_sections(post)) == 3
    end

    test "a whole flexible field shows its item count and removes the key", %{
      conn: conn,
      admin: admin,
      sections: sections,
      post: post
    } do
      {lv, _html} = open(conn, admin)
      lv |> element("#field-#{sections.id}-delete") |> render_click()

      assert has_element?(
               lv,
               "#item-delete-#{sections.id}-count[data-count='3']",
               "3 stored items"
             )

      lv |> element("#item-delete-#{sections.id}-confirm") |> render_click()

      assert {:error, _} = CMS.get_field_definition(sections.id, actor: admin)
      assert is_nil(raw_sections(post))
    end

    test "a flexible field its section's layout refuses to leave says so, and stays", %{
      conn: conn,
      admin: admin,
      sections: sections,
      post: post
    } do
      sections = CMS.update_field_definition!(sections, %{section: "Ffa Page"}, actor: admin)

      layout =
        CMS.create_field_section!(%{content_type: :post, name: "Ffa Page", display: :tab},
          actor: admin
        )

      {lv, _html} = open(conn, admin)
      lv |> element("#field-#{sections.id}-delete") |> render_click()

      # A row this release cannot load (#3062): the delete can't remove it.
      KilnCMS.Repo.query!("UPDATE field_sections SET display = $1 WHERE id = $2", [
        "zz_display_from_a_newer_release_3062",
        Ecto.UUID.dump!(layout.id)
      ])

      html = lv |> element("#item-delete-#{sections.id}-confirm") |> render_click()

      assert html =~
               "Couldn&#39;t delete that field: its section&#39;s layout could not be removed with it."

      refute html =~ "Check the count"
      # The dialog is closed: asking again would fail the same way.
      refute has_element?(lv, "#item-delete-#{sections.id}")
      assert CMS.get_field_definition!(sections.id, actor: admin)
      assert length(raw_sections(post)) == 3
    end

    test "a flexible field another admin deleted meanwhile is not blamed on its layout", %{
      conn: conn,
      admin: admin
    } do
      unused =
        def!(admin, %{
          content_type: :post,
          name: "ffa_unused",
          field_type: :flexible,
          section: "Ffa Unused"
        })

      CMS.create_field_section!(%{content_type: :post, name: "Ffa Unused", display: :tab},
        actor: admin
      )

      {lv, _html} = open(conn, admin)
      lv |> element("#field-#{unused.id}-delete") |> render_click()
      assert has_element?(lv, "#item-delete-#{unused.id}-count", "No stored items")

      :ok = CMS.destroy_field_definition!(unused, actor: admin)

      html = lv |> element("#item-delete-#{unused.id}-confirm") |> render_click()

      refute html =~ "its section&#39;s layout"
      assert html =~ "Couldn&#39;t delete that. Check the count and try again."
    end

    test "a nested flexible sub-field is deleted the same way", %{
      conn: conn,
      admin: admin,
      hero: hero
    } do
      rows = sub!(admin, hero, "rows", %{field_type: :flexible, position: 1})
      {lv, _html} = open(conn, admin)

      lv |> element("#link-field-#{rows.id}-delete") |> render_click()
      assert has_element?(lv, "#item-delete-#{rows.id}-count", "No stored items")
      lv |> element("#item-delete-#{rows.id}-confirm") |> render_click()
      assert {:error, _} = CMS.get_field_definition(rows.id, actor: admin)
    end
  end

  describe "who may do it" do
    test "an editor is redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> log_in(authed(:editor)) |> live(~p"/editor/fields")
    end

    test "an editor's writes through the code interface are refused", %{
      sections: sections,
      admin: admin
    } do
      editor = authed(:editor)
      hero = item_type!(admin, sections, "hero")

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_definition(
                 %{name: "quote", label: "Quote", field_type: :group, flex_of_id: sections.id},
                 actor: editor
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_definition(hero, %{label: "Changed"}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_field_definition(hero, %{purge_items?: true}, actor: editor)

      assert CMS.get_field_definition!(hero.id, actor: admin).label == "Hero"
    end

    test "events naming something this page did not list do nothing", %{
      conn: conn,
      admin: admin,
      sections: sections
    } do
      plain = def!(admin, %{content_type: :post, name: "ffa_plain", field_type: :string})
      hero = item_type!(admin, sections, "hero")
      {lv, _html} = open(conn, admin)

      for {event, params} <- [
            {"item_type_new", %{"parent" => plain.id}},
            {"item_type_new", %{"parent" => Ecto.UUID.generate()}},
            {"item_type_edit", %{"id" => plain.id}},
            {"item_type_edit", %{"id" => Ecto.UUID.generate()}},
            {"item_type_move", %{"id" => plain.id, "dir" => "up"}},
            {"item_delete", %{"id" => plain.id}},
            {"item_delete", %{"id" => Ecto.UUID.generate()}},
            {"link_new", %{"parent" => plain.id}}
          ] do
        render_click(lv, event, params)
      end

      refute has_element?(lv, "#item-delete-#{plain.id}")
      refute has_element?(lv, "form[phx-submit=item_type_save]")
      refute has_element?(lv, "form[phx-submit=link_save]")
      assert CMS.get_field_definition!(plain.id, actor: admin)
      assert CMS.get_field_definition!(hero.id, actor: admin)
    end

    test "another site's item type is not listed and cannot be addressed", %{
      conn: conn,
      admin: admin
    } do
      other_org =
        KilnCMS.Accounts.create_organization!(
          %{name: "Other", slug: "other-#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      other_admin =
        Ash.Seed.seed!(User, %{
          email: "flexo-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :admin,
          org_id: other_org.id
        })

      foreign =
        CMS.create_field_definition!(
          %{content_type: :post, name: "theirs", label: "Theirs", field_type: :flexible},
          actor: other_admin,
          tenant: other_org.id
        )

      foreign_item =
        CMS.create_field_definition!(
          %{name: "x", label: "X", field_type: :group, flex_of_id: foreign.id},
          actor: other_admin,
          tenant: other_org.id
        )

      {lv, html} = open(conn, admin)
      refute html =~ "Theirs"
      render_click(lv, "item_type_new", %{"parent" => foreign.id})
      render_click(lv, "item_type_edit", %{"id" => foreign_item.id})
      render_click(lv, "item_delete", %{"id" => foreign_item.id})
      refute has_element?(lv, "form[phx-submit=item_type_save]")
      refute has_element?(lv, "#item-delete-#{foreign_item.id}")

      assert CMS.get_field_definition!(foreign_item.id,
               actor: other_admin,
               tenant: other_org.id
             )
    end
  end
end
