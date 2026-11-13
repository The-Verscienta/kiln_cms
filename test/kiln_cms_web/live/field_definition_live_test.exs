defmodule KilnCMSWeb.FieldDefinitionLiveTest do
  @moduledoc """
  The admin custom-fields UI (`/editor/fields`): admins define typed fields per
  content type, and the content editor then renders an input per definition.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition

  @password "password123456"

  defp authed_user(role) do
    email = "fd-#{System.unique_integer([:positive])}@example.com"

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
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "an admin defines a custom field through the UI", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    assert html =~ "Custom fields"

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "heel_height",
        label: "Heel",
        field_type: "string"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Heel"
    assert html =~ "heel_height"

    assert :page
           |> CMS.field_definitions_for!(authorize?: false)
           |> Enum.any?(&(&1.name == "heel_height"))
  end

  test "an admin flags a field as naming the record", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "latin_name",
        label: "Latin name",
        field_type: "string",
        names_record: "true"
      }
    )
    |> render_submit()

    definition =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "latin_name"))

    assert definition.names_record == true
    assert KilnCMS.CMS.NameFields.for_resource(KilnCMS.CMS.Page, nil) == ["latin_name"]
  end

  # #2044: a private field is marked so in the list; a person field always is.
  test "an admin makes a field private", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    assert has_element?(lv, "#new-field-private")

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "internal_note",
        label: "Internal note",
        field_type: "string",
        private: "true"
      }
    )
    |> render_submit()

    definition =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "internal_note"))

    assert definition.private == true
    assert has_element?(lv, "#field-#{definition.id}-private", "private")

    # A person field says it is always private instead of asking.
    html =
      lv |> form("#new-field-form", field_definition: %{field_type: "user"}) |> render_change()

    assert html =~ "A person field is always private"
    refute has_element?(lv, "input#new-field-private")
  end

  test "an admin shares a field across locales (#1327); the default is per locale", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    assert has_element?(lv, "#new-field-form select[name='field_definition[localization]']")

    for {name, localization} <- [{"list_price", "shared"}, {"blurb", nil}] do
      params =
        %{scopes: ["page"], name: name, label: name, field_type: "string"}
        |> then(&if localization, do: Map.put(&1, :localization, localization), else: &1)

      lv |> form("#new-field-form", field_definition: params) |> render_submit()
    end

    by_name = :page |> CMS.field_definitions_for!(authorize?: false) |> Map.new(&{&1.name, &1})
    assert by_name["list_price"].localization == :shared
    assert by_name["blurb"].localization == :localized
  end

  test "an admin delivers a text field as plain text too, and only a text field", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    toggle = "#new-field-deliver-plain"

    lv |> form("#new-field-form", field_definition: %{field_type: "string"}) |> render_change()
    refute has_element?(lv, toggle)

    lv |> form("#new-field-form", field_definition: %{field_type: "text"}) |> render_change()
    assert has_element?(lv, toggle)

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "properties",
        label: "Properties",
        field_type: "text",
        deliver_plain: "true"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "properties"))

    assert field.deliver_plain
    assert lv |> element("#field-#{field.id}") |> render() =~ "plain"

    # Retyped away from text, the toggle goes and the flag with it.
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    assert has_element?(lv, "#edit-field-deliver-plain-#{field.id}[checked]")

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{field_type: "string"})
    |> render_submit()

    refute CMS.get_field_definition!(field.id, authorize?: false).deliver_plain
  end

  test "keeping paragraph breaks is offered once plain text is ticked", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    breaks = "#new-field-deliver-plain-breaks"

    lv |> form("#new-field-form", field_definition: %{field_type: "text"}) |> render_change()
    refute has_element?(lv, breaks)

    lv
    |> form("#new-field-form", field_definition: %{field_type: "text", deliver_plain: "true"})
    |> render_change()

    assert has_element?(lv, breaks)

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "actions",
        label: "Actions",
        field_type: "text",
        deliver_plain: "true",
        plain_breaks: "true"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "actions"))

    assert field.deliver_plain and field.plain_breaks

    # Unticking plain text takes the breaks with it.
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    assert has_element?(lv, "#edit-field-deliver-plain-#{field.id}-breaks[checked]")

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{deliver_plain: "false"})
    |> render_submit()

    refute CMS.get_field_definition!(field.id, authorize?: false).plain_breaks
  end

  test "an admin delivers a rich text field as Portable Text too, and only a rich one", %{
    conn: conn
  } do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    toggle = "#new-field-deliver-portable"

    lv |> form("#new-field-form", field_definition: %{field_type: "string"}) |> render_change()
    refute has_element?(lv, toggle)

    lv |> form("#new-field-form", field_definition: %{field_type: "text"}) |> render_change()
    assert has_element?(lv, toggle)

    lv
    |> form("#new-field-form", field_definition: %{field_type: "text", format: "plain"})
    |> render_change()

    refute has_element?(lv, toggle)

    lv
    |> form("#new-field-form", field_definition: %{field_type: "text", format: "rich"})
    |> render_change()

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "monograph",
        label: "Monograph",
        field_type: "text",
        format: "rich",
        deliver_portable: "true"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "monograph"))

    assert field.deliver_portable
    assert lv |> element("#field-#{field.id}") |> render() =~ "portable"

    # Switched to plain editing, the toggle goes and the flag with it.
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    assert has_element?(lv, "#edit-field-deliver-portable-#{field.id}[checked]")

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{format: "plain"})
    |> render_submit()

    refute CMS.get_field_definition!(field.id, authorize?: false).deliver_portable
  end

  test "an admin makes a media field a gallery, and is warned before narrowing it back", %{
    conn: conn
  } do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    gallery_radio = "#new-field-form input[name='field_definition[multiple]'][value=true]"

    lv |> form("#new-field-form", field_definition: %{field_type: "boolean"}) |> render_change()
    refute has_element?(lv, gallery_radio)

    lv |> form("#new-field-form", field_definition: %{field_type: "media"}) |> render_change()
    assert has_element?(lv, gallery_radio)

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "product_shots",
        label: "Product shots",
        field_type: "media",
        multiple: "true"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "product_shots"))

    assert field.multiple
    assert lv |> element("#field-#{field.id}") |> render() =~ "gallery"

    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    refute has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{multiple: "false"})
    |> render_change()

    assert has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")
  end

  test "an admin makes a reference field a bounded list, and is warned before narrowing it", %{
    conn: conn
  } do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    list_radio = "#new-field-form input[name='field_definition[multiple]'][value=true]"
    bounds = "#new-field-multiple-bounds"

    lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()
    assert has_element?(lv, list_radio)
    refute has_element?(lv, bounds)

    # Once the target is picked, the choices name it, as a relationship.
    html =
      lv
      |> form("#new-field-form",
        field_definition: %{target_types: ["page"]}
      )
      |> render_change()

    assert html =~ "One Page"
    assert html =~ "Several Page records"

    lv
    |> form("#new-field-form", field_definition: %{multiple: "true"})
    |> render_change()

    assert has_element?(lv, bounds)

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "see_also",
        label: "See also",
        kind: "relationship",
        target_types: ["page"],
        multiple: "true",
        min_items: "1",
        max_items: "5"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "see_also"))

    assert {field.multiple, field.min_items, field.max_items} == {true, 1, 5}
    assert lv |> element("#field-#{field.id}") |> render() =~ "list"

    assert lv |> element("#field-#{field.id}-links") |> render() =~
             "Each Page connects several Page records (1 to 5); each Page can be linked from any number of Page records."

    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    refute has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")

    # Blank bounds clear them.
    lv
    |> form("#edit-field-#{field.id}", field_definition: %{min_items: "", max_items: ""})
    |> render_submit()

    field = CMS.get_field_definition!(field.id, authorize?: false)
    assert {field.min_items, field.max_items} == {nil, nil}
    assert lv |> element("#field-#{field.id}-links") |> render() =~ "any number"

    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

    html =
      lv
      |> form("#edit-field-#{field.id}", field_definition: %{multiple: "false"})
      |> render_change()

    assert has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")
    assert html =~ "Saving keeps only the first item of each list"
  end

  # R1b and R5: a reference's rules about its targets, asked from the other
  # side in plain words.
  test "an admin caps how many records may link to one target, and picks a delete rule", %{
    conn: conn
  } do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    refute has_element?(lv, "#new-field-rules")
    lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()

    html =
      lv
      |> form("#new-field-form",
        field_definition: %{target_types: ["page"]}
      )
      |> render_change()

    assert has_element?(lv, "#new-field-rules")
    assert html =~ "Each Page can be linked from…"
    assert html =~ "When a linked Page is deleted for good…"
    assert has_element?(lv, "#new-field-rules-delete-keep[checked]")

    name = "seat_#{System.unique_integer([:positive])}"

    # A limit is typed only once "A limited number" is picked.
    refute has_element?(lv, "#new-field-counts-sources-limit")

    lv
    |> form("#new-field-form", field_definition: %{sources_limit: "some"})
    |> render_change()

    assert has_element?(lv, "#new-field-counts-sources-limit")

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        name: name,
        label: "Seat",
        kind: "relationship",
        target_types: ["page"],
        sources_limit: "some",
        max_sources: "3",
        on_target_delete: "restrict"
      }
    )
    |> render_submit()

    field =
      :post
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == name))

    assert {field.max_sources, field.on_target_delete} == {3, :restrict}

    assert lv |> element("#field-#{field.id}-links") |> render() =~
             "each Page can be linked from at most 3 Post records"

    assert lv |> element("#field-#{field.id}-rules") |> render() =~
             "Page records can&#39;t be deleted for good while anything links to them."

    # A blank cap clears it; the rule changes to clear.
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    assert has_element?(lv, "#edit-field-rules-#{field.id}-delete-restrict[checked]")
    assert has_element?(lv, "#edit-field-counts-#{field.id}-sources-some[checked]")

    lv
    |> form("#edit-field-#{field.id}",
      field_definition: %{max_sources: "", on_target_delete: "clear"}
    )
    |> render_submit()

    field = CMS.get_field_definition!(field.id, authorize?: false)
    assert {field.max_sources, field.on_target_delete} == {nil, :clear}

    assert lv |> element("#field-#{field.id}-rules") |> render() =~
             "Page records deleted for good are removed from the records linking to them."
  end

  # #2044: a relationship's targets can be the page's authors (or
  # contributors) in its structured data — set when adding, cleared when
  # editing, and said in the list.
  test "an admin marks a relationship as the page's authors", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()
    assert has_element?(lv, "#new-field-rules-schema-org-property")

    name = "byline_#{System.unique_integer([:positive])}"

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["post"],
        name: name,
        label: "Byline",
        kind: "relationship",
        target_types: ["page"],
        schema_org_property: "author"
      }
    )
    |> render_submit()

    field =
      :post
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == name))

    assert field.schema_org_property == :author

    assert lv |> element("#field-#{field.id}-schema-org") |> render() =~
             "Named as the page&#39;s authors in its structured data."

    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

    assert has_element?(
             lv,
             ~s(#edit-field-rules-#{field.id}-schema-org-property option[value="author"][selected])
           )

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{schema_org_property: ""})
    |> render_submit()

    field =
      :post
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == name))

    assert field.schema_org_property == nil
    refute has_element?(lv, "#field-#{field.id}-schema-org")
  end

  # R2: ticking several types stores `target_types`; ticking one keeps the
  # documented single `target_type`.
  test "an admin lets a reference field link to several types", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()

    html =
      lv
      |> form("#new-field-form",
        field_definition: %{target_types: ["page", "post"]}
      )
      |> render_change()

    assert has_element?(lv, "#new-field-targets-page[checked]")
    assert has_element?(lv, "#new-field-targets-post[checked]")
    assert html =~ "One Page or Post"

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "mentions",
        label: "Mentions",
        kind: "relationship",
        target_types: ["page", "post"],
        multiple: "true"
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "mentions"))

    assert {field.target_type, field.target_types} == {nil, ["page", "post"]}

    assert lv |> element("#field-#{field.id}-links") |> render() =~
             "Each Page connects several Page or Post records"

    # Unticking down to one type stores it the single-type way.
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{target_types: ["post"]})
    |> render_submit()

    field = CMS.get_field_definition!(field.id, authorize?: false)
    assert {field.target_type, field.target_types} == {"post", []}
  end

  # R9 (#2025): a relationship is asked for as one, Toolset-style — both sides
  # first, then how many on each — not as a "Reference" data type with
  # options under it. The stored options are what they were.
  describe "the relationship-first flow" do
    test "names both sides, asks how many on each, and reads it back as one sentence", %{
      conn: conn
    } do
      admin = authed_user(:admin)
      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # The form starts on a value; "Reference" is not a data type to pick.
      assert has_element?(lv, "#new-field-kind-value[checked]")
      refute html =~ ~s|<option value="reference"|
      refute has_element?(lv, "#new-field-sides")

      lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()

      assert has_element?(lv, "#new-field-kind-relationship[checked]")
      refute has_element?(lv, "#new-field-form select[name='field_definition[field_type]']")
      assert has_element?(lv, "#new-field-sides-sentence", "Tick a type on each side.")
      assert has_element?(lv, "#new-field-counts-sources-any[checked]")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{scopes: ["post"], target_types: ["page"]}
        )
        |> render_change()

      assert has_element?(lv, "#new-field-sides-sentence", "Post links to Page.")
      assert html =~ "Each Post connects…"
      assert html =~ "Each Page can be linked from…"
      assert html =~ "Only one Post"
      assert html =~ "What Page calls this"

      lv
      |> form("#new-field-form",
        field_definition: %{multiple: "true", sources_limit: "one", inverse_label: "Featured in"}
      )
      |> render_change()

      assert has_element?(
               lv,
               "#new-field-summary",
               "Each Post connects several Page records (any number); each Page can be linked from only one Post. Each Page lists them as “Featured in”."
             )

      name = "features_#{System.unique_integer([:positive])}"

      lv
      |> form("#new-field-form", field_definition: %{label: "Features", name: name})
      |> render_submit()

      field =
        :post |> CMS.field_definitions_for!(authorize?: false) |> Enum.find(&(&1.name == name))

      assert {field.field_type, field.target_type, field.multiple, field.max_sources,
              field.inverse_label} == {:reference, "page", true, 1, "Featured in"}

      assert has_element?(
               lv,
               "#field-#{field.id}-links",
               "Each Post connects several Page records (any number); each Page can be linked from only one Post."
             )

      # The edit form asks the same way; its own side is fixed.
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-kind-#{field.id}-relationship[checked]")
      assert has_element?(lv, "#edit-field-sides-#{field.id}-sentence", "Post links to Page.")
      assert has_element?(lv, "#edit-field-counts-#{field.id}-sources-one[checked]")

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{sources_limit: "any"})
      |> render_submit()

      assert CMS.get_field_definition!(field.id, authorize?: false).max_sources == nil
    end

    test "going back to a value brings back the type picker", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()
      lv |> form("#new-field-form", field_definition: %{kind: "value"}) |> render_change()

      assert has_element?(lv, "#new-field-kind-value[checked]")
      refute has_element?(lv, "#new-field-sides")

      assert has_element?(
               lv,
               "#new-field-form select[name='field_definition[field_type]'] option[value=string][selected]"
             )
    end
  end

  test "non-admins are redirected away", %{conn: conn} do
    editor = authed_user(:editor)

    assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
             conn |> log_in(editor) |> live(~p"/editor/fields")
  end

  test "the content editor renders an input per defined field", %{conn: conn} do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "heel_height",
        label: "Heel height",
        field_type: :string
      },
      actor: admin
    )

    page =
      CMS.create_page!(%{title: "Shoe", slug: "fd-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ "Custom fields"
    assert html =~ "Heel height"
    assert html =~ "custom_fields][heel_height]"
  end

  test "a broken formula is refused when the computed field is defined", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    # The formula input only appears once the type is `computed` — the same
    # conditional treatment `target_type` gets for `:reference` — and a new
    # field starts in the recipe view, so the hand-written formula needs the
    # formula view.
    form = form(lv, "#new-field-form", field_definition: %{field_type: "computed"})
    assert render_change(form) =~ "Formula"

    lv
    |> form("#new-field-form",
      field_definition: %{field_type: "computed", builder: %{mode: "formula"}}
    )
    |> render_change()

    html =
      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "reading_time",
          label: "Reading time",
          field_type: "computed",
          compute: "{{ slugfy(title) }}"
        }
      )
      |> render_submit()

    assert html =~ "unknown function slugfy/1"

    refute :page
           |> CMS.field_definitions_for!(authorize?: false)
           |> Enum.any?(&(&1.name == "reading_time"))
  end

  test "the editor renders a geolocation field as one input per part", %{conn: conn} do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "store",
        label: "Store location",
        field_type: :geolocation
      },
      actor: admin
    )

    page =
      CMS.create_page!(%{title: "Store", slug: "fd-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ "Store location"
    assert html =~ "custom_fields][store][lat]"
    assert html =~ "custom_fields][store][lng]"
    assert html =~ "custom_fields][store][zoom]"
  end

  test "the editor renders a computed field read-only and live", %{conn: conn} do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "url_key",
        label: "URL key",
        field_type: :computed,
        compute: "{{ slugify(title) }}"
      },
      actor: admin
    )

    page =
      CMS.create_page!(%{title: "First Title", slug: "fd-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ "URL key"
    assert html =~ "readonly"
    assert html =~ "first-title"

    # Retyping the title recomputes it in place, without a save.
    html = render_change(form(lv, "#page-editor"), %{"form" => %{"title" => "Second Title"}})

    assert html =~ "second-title"
  end

  describe "the field type description" do
    test "follows the type picked in the add form", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # The form starts on String, and says what that is before any change.
      assert html =~ "A single line of text."

      html =
        lv
        |> form("#new-field-form", field_definition: %{field_type: "select"})
        |> render_change()

      assert html =~ "One choice from a fixed list"
      refute html =~ "A single line of text."

      html =
        lv
        |> form("#new-field-form", field_definition: %{field_type: "datetime_range"})
        |> render_change()

      assert html =~ "gets a calendar feed"
    end

    test "is shown in the edit form too", %{conn: conn} do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{content_type: :page, name: "venue", label: "Venue", field_type: :geolocation},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      assert lv |> element("#edit-field-#{field.id}") |> render() =~ "A point on a map"

      html =
        lv
        |> form("#edit-field-#{field.id}", field_definition: %{field_type: "boolean"})
        |> render_change()

      assert html =~ "A yes-or-no checkbox."
    end

    test "every built-in type has one", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      for type <- KilnCMS.CMS.FieldTypes.reserved() do
        html =
          lv
          |> element("#new-field-form")
          |> render_change(%{"field_definition" => %{"field_type" => to_string(type)}})

        assert type_hint(html) not in [nil, ""],
               "no description under the picker for #{inspect(type)}"
      end
    end
  end

  describe "the machine name" do
    test "follows the label until the admin edits it", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      label_change(lv, "Shoe size (EU)", "")
      assert name_value(lv) == "shoe_size_eu"

      # Retyping the label moves the suggestion with it.
      label_change(lv, "Heel height", "shoe_size_eu")
      assert name_value(lv) == "heel_height"

      # Typing into the name takes it over: the label no longer rewrites it.
      lv
      |> form("#new-field-form")
      |> render_change(%{
        "_target" => ["field_definition", "name"],
        "field_definition" => %{"label" => "Heel height", "name" => "heel"}
      })

      label_change(lv, "Heel height (cm)", "heel")
      assert name_value(lv) == "heel"

      # Clearing the name hands it back to the label.
      lv
      |> form("#new-field-form")
      |> render_change(%{
        "_target" => ["field_definition", "name"],
        "field_definition" => %{"label" => "Heel height (cm)", "name" => ""}
      })

      label_change(lv, "Heel height (mm)", "")
      assert name_value(lv) == "heel_height_mm"
    end

    test "a submit with no name uses the one the label suggests", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form",
        field_definition: %{scopes: ["page"], label: "Crème brûlée", field_type: "string"}
      )
      |> render_submit()

      assert :page
             |> CMS.field_definitions_for!(authorize?: false)
             |> Enum.any?(&(&1.name == "creme_brulee" and &1.label == "Crème brûlée"))
    end
  end

  test "name_from_label/1 suggests a name the validation accepts" do
    assert FieldDefinition.name_from_label("Shoe size (EU)") == "shoe_size_eu"
    assert FieldDefinition.name_from_label("  Crème   brûlée!! ") == "creme_brulee"
    assert FieldDefinition.name_from_label("3D model") == "field_3d_model"
    assert FieldDefinition.name_from_label("日本") == ""
    assert FieldDefinition.name_from_label(nil) == ""
  end

  describe "a duplicate machine name" do
    test "is flagged while typing and refused on submit", %{conn: conn} do
      admin = authed_user(:admin)
      create_field!(admin, :page, "heel_height")
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form")
        |> render_change(%{
          "_target" => ["field_definition", "label"],
          "field_definition" => %{"scopes" => ["", "page"], "label" => "Heel height"}
        })

      assert html =~ "is already a field on Page"

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            scopes: ["page"],
            name: "heel_height",
            label: "Heel height again",
            field_type: "string"
          }
        )
        |> render_submit()

      assert html =~ "is already a field on Page"
      refute html =~ "Field added"

      assert [_only_the_original] =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.filter(&(&1.name == "heel_height"))
    end

    test "on one ticked type writes nothing to the others", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      create_field!(admin, :page, "servings")
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            # The taken type last, so a create-as-you-go loop would already
            # have written the recipe's copy by the time it hit the page's.
            scopes: ["def:#{recipe.id}", "page"],
            name: "servings",
            label: "Servings",
            field_type: "integer"
          }
        )
        |> render_submit()

      assert html =~ "is already a field on Page"
      assert CMS.field_definitions_for_definition!(recipe.id, authorize?: false) == []
    end

    test "on a type that is not ticked is allowed", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      create_field!(admin, :page, "servings")
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            scopes: ["def:#{recipe.id}"],
            name: "servings",
            label: "Servings",
            field_type: "integer"
          }
        )
        |> render_submit()

      refute html =~ "is already a field"

      assert [%{name: "servings"}] =
               CMS.field_definitions_for_definition!(recipe.id, authorize?: false)
    end
  end

  describe "several content types" do
    test "get one field each, under the same machine name", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            scopes: ["page", "def:#{recipe.id}"],
            label: "Prep time",
            field_type: "integer",
            required: "true"
          }
        )
        |> render_submit()

      assert html =~ "Field added to 2 content types."

      assert [%{label: "Prep time", field_type: :integer, required: true} = on_page] =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.filter(&(&1.name == "prep_time"))

      assert [%{label: "Prep time", field_type: :integer, required: true} = on_recipe] =
               CMS.field_definitions_for_definition!(recipe.id, authorize?: false)

      # Two rows, not one shared: each is edited on its own.
      assert on_page.id != on_recipe.id
      assert on_page.content_type == :page and on_page.type_definition_id == nil
      assert on_recipe.content_type == nil and on_recipe.type_definition_id == recipe.id

      # The form starts over, types unticked.
      refute has_element?(lv, "#new-field-form input[type=checkbox][value=page][checked]")
    end

    test "none ticked is refused with a message", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{label: "Orphan", name: "orphan", field_type: "string"}
        )
        |> render_submit()

      assert html =~ "Pick at least one content type."

      refute CMS.list_field_definitions!(authorize?: false)
             |> Enum.any?(&(&1.name == "orphan"))
    end
  end

  # #1817: the content-types screen sends a new type here with `?type=`.
  describe "a type in the URL" do
    test "starts ticked, and stays ticked after a field is added", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      scope = "def:#{recipe.id}"

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields?#{[type: scope]}")

      assert has_element?(lv, ~s|#new-field-form input[type=checkbox][value="#{scope}"][checked]|)
      refute has_element?(lv, "#new-field-form input[type=checkbox][value=page][checked]")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{label: "Servings", field_type: "integer"}
        )
        |> render_submit()

      assert html =~ "Field added."

      assert [%{name: "servings"}] =
               CMS.field_definitions_for_definition!(recipe.id, authorize?: false)

      # Ready for the next field on the same type.
      assert has_element?(lv, ~s|#new-field-form input[type=checkbox][value="#{scope}"][checked]|)
    end

    test "that the page offers no checkbox for is ignored", %{conn: conn} do
      admin = authed_user(:admin)

      for type <- ["def:#{Ecto.UUID.generate()}", "not_a_type", "orphaned:gone"] do
        {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields?#{[type: type]}")
        refute has_element?(lv, "#new-field-form input[type=checkbox][checked]")
      end
    end

    # #1770's crash path, with a dynamic scope ticked from the URL.
    test "still renders beside an orphaned field", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      create_dynamic_field!(admin, recipe, "servings", 0)
      id = insert_orphan!("gone_type_#{System.unique_integer([:positive])}", "stale_field")

      {:ok, lv, html} =
        conn |> log_in(admin) |> live(~p"/editor/fields?#{[type: "def:#{recipe.id}"]}")

      assert html =~ "servings"
      assert has_element?(lv, "#orphaned-fields #field-#{id}", "stale_field")

      assert has_element?(
               lv,
               ~s|#new-field-form input[type=checkbox][value="def:#{recipe.id}"][checked]|
             )
    end
  end

  # #1819: the options box is for select fields only.
  describe "the options box" do
    test "shows only for a select field", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      refute has_element?(lv, "#new-field-options")

      type_change(lv, "select")
      assert has_element?(lv, "#new-field-options")

      for type <- ~w(string text integer boolean media reference computed geolocation) do
        type_change(lv, type)
        refute has_element?(lv, "#new-field-options"), "options box shown for #{type}"
      end
    end

    test "a field changed away from select keeps no options", %{conn: conn} do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "size",
            label: "Size",
            field_type: :select,
            options: ["S", "M"],
            default: "M"
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-options-#{field.id}")

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "string"})
      |> render_change()

      refute has_element?(lv, "#edit-field-options-#{field.id}")

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "string"})
      |> render_submit()

      saved = CMS.get_field_definition!(field.id, actor: admin)
      assert saved.field_type == :string
      assert saved.options == []
      # "M" was a choice, not a string anyone typed.
      assert saved.default == nil
    end
  end

  # #1820: a default only where one can be typed, in an input that fits.
  describe "the default value" do
    test "shows only for types that take one, in a fitting input", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")
      default = ~s|#new-field-form [name="field_definition[default]"]|

      # String, the starting type.
      assert has_element?(
               lv,
               ~s|#new-field-form input[type=text][name="field_definition[default]"]|
             )

      for type <- ~w(media computed geolocation datetime_range recurrence) do
        type_change(lv, type)
        refute has_element?(lv, default), "default shown for #{type}"
      end

      lv |> form("#new-field-form", field_definition: %{kind: "relationship"}) |> render_change()
      refute has_element?(lv, default), "default shown for a relationship"
      lv |> form("#new-field-form", field_definition: %{kind: "value"}) |> render_change()

      type_change(lv, "integer")
      assert has_element?(lv, ~s|#new-field-form input[type=number][step="1"]#{default_attr()}|)

      type_change(lv, "float")
      assert has_element?(lv, ~s|#new-field-form input[type=number][step=any]#{default_attr()}|)

      type_change(lv, "boolean")
      assert has_element?(lv, ~s|#new-field-form input[type=checkbox]#{default_attr()}|)

      type_change(lv, "date")
      assert has_element?(lv, ~s|#new-field-form input[type=date]#{default_attr()}|)

      type_change(lv, "select")
      assert has_element?(lv, ~s|#new-field-form select#{default_attr()}|)
    end

    test "a date field can take today's date instead of a fixed value (#2286)", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      type_change(lv, "date")

      source = ~s|#new-field-form select[name="field_definition[default_source]"]|
      assert has_element?(lv, source <> " option[value=today]")
      refute has_element?(lv, source <> " option[value=now]")

      lv
      |> form("#new-field-form",
        field_definition: %{scopes: ["page"], label: "Opened on", field_type: "date"}
      )
      |> render_change(%{"field_definition" => %{"default_source" => "today"}})

      # The fixed-value input steps aside for the source.
      refute has_element?(lv, ~s|#new-field-form input[type=date]#{default_attr()}|)

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          label: "Opened on",
          field_type: "date",
          default_source: "today"
        }
      )
      |> render_submit()

      assert [%{default_source: :today, default: nil}] =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.filter(&(&1.name == "opened_on"))
    end

    test "a select's default is picked from its options", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      type_change(lv, "select")

      lv
      |> element("#new-field-form")
      |> render_change(%{
        "_target" => ["field_definition", "options"],
        "field_definition" => %{"field_type" => "select", "options" => "Small\nLarge"}
      })

      assert has_element?(lv, ~s|#new-field-form select#{default_attr()} option[value=Large]|)

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          label: "Size",
          field_type: "select",
          options: "Small\nLarge",
          default: "Large"
        }
      )
      |> render_submit()

      assert [%{options: ["Small", "Large"], default: "Large"}] =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.filter(&(&1.name == "size"))
    end

    test "a ticked yes-or-no default is saved as true", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      type_change(lv, "boolean")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          label: "Featured",
          field_type: "boolean",
          default: "true"
        }
      )
      |> render_submit()

      assert [%{default: "true"}] =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.filter(&(&1.name == "featured"))
    end

    test "picking another type clears it", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> element("#new-field-form")
      |> render_change(%{
        "_target" => ["field_definition", "default"],
        "field_definition" => %{"field_type" => "string", "default" => "abc"}
      })

      assert default_value(lv) == "abc"

      lv
      |> element("#new-field-form")
      |> render_change(%{
        "_target" => ["field_definition", "field_type"],
        "field_definition" => %{"field_type" => "integer", "default" => "abc"}
      })

      assert default_value(lv) in [nil, ""]
    end

    test "is not saved for a type that takes none", %{conn: conn} do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{content_type: :page, name: "hero", label: "Hero", field_type: :string, default: "x"},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "media"})
      |> render_change()

      refute has_element?(lv, ~s|#edit-field-#{field.id} [name="field_definition[default]"]|)

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "media"})
      |> render_submit()

      saved = CMS.get_field_definition!(field.id, actor: admin)
      assert saved.field_type == :media
      assert saved.default == nil
    end
  end

  # #1818: the order of a type's fields is the order the editor shows them in,
  # set by dragging (the `Sortable` hook's "reorder") or the arrow buttons.
  describe "the order of fields" do
    test "no position number on the forms", %{conn: conn} do
      admin = authed_user(:admin)
      field = create_field!(admin, :page, "one")
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      refute has_element?(lv, ~s|#new-field-form [name="field_definition[position]"]|)
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      refute has_element?(lv, ~s|#edit-field-#{field.id} [name="field_definition[position]"]|)
    end

    test "a new field goes last", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      create_dynamic_field!(admin, recipe, "first", 0)
      create_dynamic_field!(admin, recipe, "second", 4)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form",
        field_definition: %{scopes: ["def:#{recipe.id}"], label: "Aardvark", field_type: "string"}
      )
      |> render_submit()

      assert recipe_order(recipe) == ["first", "second", "aardvark"]
    end

    test "a drag saves the new order", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      a = create_dynamic_field!(admin, recipe, "a", 0)
      b = create_dynamic_field!(admin, recipe, "b", 1)
      c = create_dynamic_field!(admin, recipe, "c", 2)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert has_element?(
               lv,
               "#fields-def-#{recipe.id}[phx-hook=Sortable] > li[data-sort-id='#{a.id}']"
             )

      lv
      |> element("#fields-def-#{recipe.id}")
      |> render_hook("reorder", %{"order" => [c.id, a.id, b.id]})

      assert recipe_order(recipe) == ["c", "a", "b"]
      assert list_order(lv, recipe) == [c.id, a.id, b.id]
    end

    test "a drag naming some other set of fields changes nothing", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      a = create_dynamic_field!(admin, recipe, "a", 0)
      b = create_dynamic_field!(admin, recipe, "b", 1)
      other = create_field!(admin, :page, "other")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      for order <- [[b.id], [b.id, a.id, other.id], [b.id, other.id], [b.id, b.id]] do
        lv
        |> element("#fields-def-#{recipe.id}")
        |> render_hook("reorder", %{"order" => order})
      end

      assert recipe_order(recipe) == ["a", "b"]
    end

    test "the arrows move a field one place", %{conn: conn} do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      a = create_dynamic_field!(admin, recipe, "a", 0)
      b = create_dynamic_field!(admin, recipe, "b", 0)
      c = create_dynamic_field!(admin, recipe, "c", 0)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # The ends can't move further out.
      assert has_element?(lv, "#field-#{a.id} button[phx-value-dir=up][disabled]")
      assert has_element?(lv, "#field-#{c.id} button[phx-value-dir=down][disabled]")

      lv |> element("#field-#{c.id} button[phx-value-dir=up]") |> render_click()
      assert recipe_order(recipe) == ["a", "c", "b"]

      lv |> element("#field-#{a.id} button[phx-value-dir=down]") |> render_click()
      assert recipe_order(recipe) == ["c", "a", "b"]
      assert list_order(lv, recipe) == [c.id, a.id, b.id]

      assert has_element?(
               lv,
               ~s|#field-#{b.id} button[aria-label="Move b down"][disabled]|
             )
    end
  end

  defp type_change(lv, type) do
    lv
    |> element("#new-field-form")
    |> render_change(%{
      "_target" => ["field_definition", "field_type"],
      "field_definition" => %{"field_type" => type}
    })
  end

  defp default_attr, do: ~s|[name="field_definition[default]"]|

  defp default_value(lv) do
    lv
    |> element(~s|#new-field-form input[name="field_definition[default]"]|)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> List.first()
  end

  defp create_dynamic_field!(admin, recipe, name, position) do
    CMS.create_field_definition!(
      %{
        type_definition_id: recipe.id,
        name: name,
        label: name,
        field_type: :string,
        position: position
      },
      actor: admin
    )
  end

  defp recipe_order(recipe),
    do:
      recipe.id |> CMS.field_definitions_for_definition!(authorize?: false) |> Enum.map(& &1.name)

  defp list_order(lv, recipe) do
    lv
    |> element("#fields-def-#{recipe.id}")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("li", "data-sort-id")
  end

  # The help text under the add form's type picker: the wrapper holding the
  # select, then its hint paragraph.
  defp type_hint(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#new-field-form div.mb-2:has(select#field_definition_field_type) > p.text-xs")
    |> Floki.text()
    |> String.trim()
  end

  defp label_change(lv, label, name) do
    lv
    |> form("#new-field-form")
    |> render_change(%{
      "_target" => ["field_definition", "label"],
      "field_definition" => %{"label" => label, "name" => name}
    })
  end

  # #1770: a row whose stored content type no longer exists (a removed plugin,
  # a renamed or deleted type). A write cannot make one, so it goes in as raw
  # SQL, the way an upgraded database already holds it; the name is built at
  # runtime so no atom of it exists — the case that used to crash the read.
  describe "an orphaned field" do
    test "the screen still renders, listing it apart as orphaned", %{conn: conn} do
      admin = authed_user(:admin)
      create_field!(admin, :page, "live_field")
      gone = "gone_type_#{System.unique_integer([:positive])}"
      id = insert_orphan!(gone, "stale_field")

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert html =~ "live_field"
      assert has_element?(lv, "#orphaned-fields #field-#{id}", "stale_field")
      assert has_element?(lv, "#orphaned-fields #field-#{id}", gone)
      assert has_element?(lv, "#orphaned-fields", "Orphaned fields")
      # Not offered for editing: it cannot be saved while it points at nothing.
      refute has_element?(lv, "#field-#{id} button[phx-click=edit]")
    end

    test "an admin deletes it from the screen", %{conn: conn} do
      admin = authed_user(:admin)
      id = insert_orphan!("gone_type_#{System.unique_integer([:positive])}", "stale_field")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv |> element("#field-#{id} button[phx-click=delete]") |> render_click()

      refute has_element?(lv, "#orphaned-fields")
      assert render(lv) =~ "Field deleted."
      assert {:error, _} = CMS.get_field_definition(id, actor: admin)
    end
  end

  # A field of a type this release does not know (#2605): a newer release's,
  # after a rollback, or a removed plugin's.
  describe "a field of an unknown type" do
    setup do
      admin = authed_user(:admin)
      recipe = type_definition!(admin, "Recipe")
      a = create_dynamic_field!(admin, recipe, "a", 0)
      b = create_dynamic_field!(admin, recipe, "b", 1)

      held =
        KilnCMS.NewerReleaseRows.field_definition!(%{
          content_type: nil,
          type_definition_id: recipe.id,
          name: "specs",
          position: 1
        })

      %{admin: admin, recipe: recipe, a: a, b: b, held: held}
    end

    test "the screen lists it apart, with only a delete", %{conn: conn} = ctx do
      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      assert has_element?(lv, "#unknown-type-fields #field-#{ctx.held}", "specs")

      assert has_element?(
               lv,
               "#unknown-type-fields #field-#{ctx.held}",
               KilnCMS.NewerReleaseRows.unknown_field_type()
             )

      assert has_element?(lv, "#unknown-type-fields", "Fields of an unknown type")
      refute has_element?(lv, "#field-#{ctx.held} button[phx-click=edit]")
      refute has_element?(lv, "#fields-def-#{ctx.recipe.id} li[data-sort-id='#{ctx.held}']")

      # A hand-made edit event for it changes nothing.
      render_click(lv, "edit", %{"id" => ctx.held})
      assert render(lv) =~ "That field can&#39;t be edited."
    end

    test "an admin deletes it from the screen", %{conn: conn} = ctx do
      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv
      |> element("#unknown-type-fields #field-#{ctx.held} button[phx-click=delete]")
      |> render_click()

      refute has_element?(lv, "#unknown-type-fields")
      assert render(lv) =~ "Field deleted."

      assert {:error, _} =
               CMS.get_field_definition(ctx.held,
                 actor: ctx.admin,
                 context: FieldDefinition.all_types_context()
               )
    end

    test "editing a field whose condition reads it keeps that condition",
         %{conn: conn} = ctx do
      rule = %{"field" => "specs", "op" => "not_empty"}

      KilnCMS.Repo.query!(
        "UPDATE field_definitions SET visible_when = $1 WHERE id = $2",
        [rule, Ecto.UUID.dump!(ctx.a.id)]
      )

      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv |> element("#field-#{ctx.a.id} button[phx-click=edit]") |> render_click()
      assert render(lv) =~ "reads a field of a type this version of Kiln"

      lv
      |> form("#edit-field-#{ctx.a.id}", field_definition: %{label: "Renamed"})
      |> render_submit()

      saved = CMS.get_field_definition!(ctx.a.id, actor: ctx.admin)
      assert saved.label == "Renamed"
      assert saved.visible_when == rule
    end

    test "a sub-field of an unknown type is listed under its group, with a delete",
         %{conn: conn} = ctx do
      group =
        CMS.create_field_definition!(
          %{
            type_definition_id: ctx.recipe.id,
            name: "dosages",
            label: "Dosages",
            field_type: :group
          },
          actor: ctx.admin
        )

      sub =
        KilnCMS.NewerReleaseRows.field_definition!(%{
          content_type: nil,
          group_of_id: group.id,
          name: "rated"
        })

      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      assert has_element?(lv, "#unknown-type-fields #field-#{sub}", "rated")
      assert has_element?(lv, "#unknown-type-fields #field-#{sub}", "On Dosages")

      lv
      |> element("#unknown-type-fields #field-#{sub} button[phx-click=delete]")
      |> render_click()

      assert render(lv) =~ "Field deleted."

      assert {:error, _} =
               CMS.get_field_definition(sub,
                 actor: ctx.admin,
                 context: FieldDefinition.all_types_context()
               )
    end

    test "a delete another field's condition refuses says which field", %{conn: conn} = ctx do
      KilnCMS.Repo.query!(
        "UPDATE field_definitions SET visible_when = $1 WHERE id = $2",
        [%{"field" => "specs", "op" => "not_empty"}, Ecto.UUID.dump!(ctx.a.id)]
      )

      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv
      |> element("#unknown-type-fields #field-#{ctx.held} button[phx-click=delete]")
      |> render_click()

      assert render(lv) =~ "a reads this field in a condition: remove that condition first."
      assert has_element?(lv, "#unknown-type-fields #field-#{ctx.held}")
    end

    test "a drag on its type reorders the known fields and leaves it alone",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = conn |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv
      |> element("#fields-def-#{ctx.recipe.id}")
      |> render_hook("reorder", %{"order" => [ctx.b.id, ctx.a.id]})

      assert recipe_order(ctx.recipe) == ["b", "a"]
      assert list_order(lv, ctx.recipe) == [ctx.b.id, ctx.a.id]

      held =
        CMS.get_field_definition!(ctx.held,
          actor: ctx.admin,
          context: FieldDefinition.all_types_context()
        )

      assert held.position == 1
    end
  end

  defp insert_orphan!(content_type, name) do
    id = Ecto.UUID.generate()

    KilnCMS.Repo.query!(
      """
      INSERT INTO field_definitions
        (id, org_id, content_type, name, label, field_type, required, options,
         position, names_record, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4, 'string', false, '{}', 0, false, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(KilnCMS.Accounts.default_org_id()),
        content_type,
        name
      ]
    )

    id
  end

  defp name_value(lv) do
    lv
    |> element(~s|#new-field-form input[name="field_definition[name]"]|)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> List.first()
  end

  defp create_field!(admin, content_type, name) do
    CMS.create_field_definition!(
      %{content_type: content_type, name: name, label: name, field_type: :string},
      actor: admin
    )
  end

  defp type_definition!(admin, label) do
    CMS.create_type_definition!(
      %{name: "fd#{System.unique_integer([:positive])}", label: label},
      actor: admin
    )
  end

  # The formula builder: a recipe view for admins who don't write formulas, a
  # formula view with palettes for those who do, and a preview for both.
  describe "the computed-field builder" do
    defp computed_change(lv, field_definition) do
      lv
      |> element("#new-field-form")
      |> render_change(%{
        "field_definition" =>
          Map.merge(%{"field_type" => "computed", "scopes" => ["page"]}, field_definition)
      })
    end

    test "a recipe writes the formula, previews it, and is what gets saved", %{conn: conn} do
      admin = authed_user(:admin)

      CMS.create_page!(
        %{
          title: "Preview me",
          slug: "fd-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "quote", "text" => String.duplicate("word ", 460)}]
        },
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      html = computed_change(lv, %{})
      assert html =~ "Pick what this field should work out"
      assert has_element?(lv, "#new-field-recipe-reading_time")

      html =
        computed_change(lv, %{"builder" => %{"mode" => "recipe", "recipe" => "reading_time"}})

      assert has_element?(lv, ~s|#new-field-compute[value="{{ reading_time(body) }} min read"]|)
      assert html =~ "Preview me"
      assert has_element?(lv, "#new-field-preview output", "2 min read")

      lv
      |> element("#new-field-form")
      |> render_submit(%{
        "field_definition" => %{
          "scopes" => ["page"],
          "label" => "Reading time",
          "name" => "reading_minutes",
          "field_type" => "computed",
          "compute" => "",
          "builder" => %{
            "mode" => "recipe",
            "recipe" => "reading_time",
            "slots" => %{"source" => "body", "suffix" => "minutes"}
          }
        }
      })

      saved =
        :page
        |> CMS.field_definitions_for!(authorize?: false)
        |> Enum.find(&(&1.name == "reading_minutes"))

      assert saved.compute == "{{ reading_time(body) }} minutes"
    end

    test "a recipe's value picker offers the type's other fields", %{conn: conn} do
      admin = authed_user(:admin)

      CMS.create_field_definition!(
        %{content_type: :page, name: "price", label: "Price", field_type: :integer},
        actor: admin
      )

      CMS.create_page!(
        %{
          title: "Pricey",
          slug: "fd-#{System.unique_integer([:positive])}",
          custom_fields: %{"price" => 150}
        },
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      computed_change(lv, %{"builder" => %{"mode" => "recipe", "recipe" => "conditional"}})
      assert has_element?(lv, ~s|#new-field-slot-value option[value="price"]|, "Price")

      computed_change(lv, %{
        "builder" => %{
          "mode" => "recipe",
          "recipe" => "conditional",
          "slots" => %{
            "value" => "price",
            "operator" => "greater_than",
            "compare" => "100",
            "then" => "Premium",
            "otherwise" => "Standard"
          }
        }
      })

      assert has_element?(
               lv,
               ~s|#new-field-compute[value='{{ if(greater_than(price, 100), "Premium", "Standard") }}']|
             )

      assert has_element?(lv, "#new-field-preview output", "Premium")

      # "is empty" compares with nothing, so its box goes away.
      computed_change(lv, %{
        "builder" => %{
          "mode" => "recipe",
          "recipe" => "conditional",
          "slots" => %{"operator" => "is_empty"}
        }
      })

      refute has_element?(lv, "#new-field-slot-compare")
    end

    test "the formula view lists the functions and values, and previews errors", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      computed_change(lv, %{"builder" => %{"mode" => "formula"}})

      assert has_element?(lv, "#new-field-formula[phx-hook]")
      assert has_element?(lv, ~s|#new-field-formula button[data-insert-fn="days_between"]|)
      assert has_element?(lv, ~s|#new-field-formula button[data-insert-ref="body"]|, "Body text")

      computed_change(lv, %{
        "builder" => %{"mode" => "formula"},
        "compute" => "{{ upcase(title) }}"
      })

      # No pages yet, so the preview runs on sample text.
      assert has_element?(lv, "#new-field-preview output", "A SAMPLE TITLE")

      computed_change(lv, %{
        "builder" => %{"mode" => "formula"},
        "compute" => "{{ upcse(title) }}"
      })

      assert has_element?(lv, "#new-field-preview", "calls unknown function upcse/1")
    end

    test "other computed fields are offered and previewed in dependency order, less loops",
         %{conn: conn} do
      admin = authed_user(:admin)

      define = fn name, label, compute ->
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: name,
            label: label,
            field_type: :computed,
            compute: compute
          },
          actor: admin
        )
      end

      # Created before either field, so it stores neither value: the preview
      # must derive the chain, not read the sample's jsonb.
      CMS.create_page!(
        %{title: "Preview me", slug: "fd-#{System.unique_integer([:positive])}"},
        actor: admin
      )

      base = define.("url_base", "URL base", "{{ slugify(title) }}")
      define.("url_loud", "URL loud", "{{ upcase(url_base) }}")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # The recipe pickers offer them, and so does the formula palette.
      computed_change(lv, %{"builder" => %{"mode" => "recipe", "recipe" => "conditional"}})
      assert has_element?(lv, ~s|#new-field-slot-value option[value="url_base"]|, "URL base")

      computed_change(lv, %{"builder" => %{"mode" => "formula"}})

      assert has_element?(
               lv,
               ~s|#new-field-formula button[data-insert-ref="url_loud"]|,
               "URL loud"
             )

      computed_change(lv, %{
        "builder" => %{"mode" => "formula"},
        "compute" => "{{ concat(url_loud, '!') }}"
      })

      assert has_element?(lv, "#new-field-preview output", "PREVIEW-ME!")

      # Editing `url_base`: `url_loud` reads it, so offering it would offer a loop.
      lv |> element("#field-#{base.id} button[phx-click=edit]") |> render_click()

      lv
      |> element("#edit-field-#{base.id}")
      |> render_change(%{
        "field_definition" => %{
          "field_type" => "computed",
          "compute" => "{{ slugify(title) }}",
          "builder" => %{"mode" => "formula"}
        }
      })

      refute has_element?(
               lv,
               ~s|#edit-field-#{base.id}-formula button[data-insert-ref="url_loud"]|
             )

      # And a formula typed by hand into a loop says so.
      lv
      |> element("#edit-field-#{base.id}")
      |> render_change(%{
        "field_definition" => %{
          "field_type" => "computed",
          "compute" => "{{ url_loud }}",
          "builder" => %{"mode" => "formula"}
        }
      })

      assert render(lv) =~ "makes a loop: url_base → url_loud → url_base"
    end

    test "today() is in the Dates palette, previews on today's date, and says it refreshes daily",
         %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      computed_change(lv, %{"builder" => %{"mode" => "formula"}})

      assert has_element?(
               lv,
               ~s|#new-field-formula button[data-insert-fn="today"]|,
               "refreshed once a day"
             )

      refute has_element?(lv, "#new-field-daily")

      html =
        computed_change(lv, %{"builder" => %{"mode" => "formula"}, "compute" => "{{ today() }}"})

      # The preview evaluates on the date the note names — the one a save made
      # now would pin — rather than leaving `today()` blank.
      [date] = Regex.run(~r/date \((\d{4}-\d{2}-\d{2})\)/, html, capture: :all_but_first)
      assert has_element?(lv, "#new-field-preview output", date)
      assert has_element?(lv, "#new-field-daily", "refreshed once a day")

      computed_change(lv, %{
        "builder" => %{"mode" => "recipe", "recipe" => "days_until"},
        "compute" => "{{ today() }}"
      })

      assert has_element?(lv, "#new-field-recipe-days_until")
      assert has_element?(lv, "#new-field-recipe-age")
    end

    test "editing reopens a recipe's field in the recipe view, a hand formula in the formula view",
         %{conn: conn} do
      admin = authed_user(:admin)

      recipe =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "page_slug",
            label: "Slug",
            field_type: :computed,
            compute: "{{ slugify(title) }}"
          },
          actor: admin
        )

      hand =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "shout",
            label: "Shout",
            field_type: :computed,
            compute: "{{ upcase(slugify(title)) }}"
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv |> element("#field-#{recipe.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-#{recipe.id}-recipe-slug[checked]")

      lv |> element("#field-#{hand.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-#{hand.id}-formula textarea", "upcase(slugify(title))")

      # Switching it to the recipe view keeps the formula until a recipe is
      # picked, and says so.
      lv
      |> element("#edit-field-#{hand.id}")
      |> render_change(%{
        "field_definition" => %{
          "field_type" => "computed",
          "compute" => "{{ upcase(slugify(title)) }}",
          "builder" => %{"mode" => "recipe"}
        }
      })

      assert render(lv) =~ "doesn&#39;t match a recipe"

      assert has_element?(
               lv,
               ~s|#edit-field-#{hand.id}-compute[value="{{ upcase(slugify(title)) }}"]|
             )
    end
  end

  describe "value constraints (#2276)" do
    defp validation_input(name),
      do: ~s|#new-field-validation [name="field_definition[validation][#{name}]"]|

    test "the Validation fieldset offers the inputs the type takes", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      # String, the starting type.
      for key <- ~w(min_length max_length pattern pattern_message unique) do
        assert has_element?(lv, validation_input(key)), "#{key} missing on a string"
      end

      refute has_element?(lv, validation_input("min"))

      type_change(lv, "integer")
      for key <- ~w(min max unique), do: assert(has_element?(lv, validation_input(key)))
      refute has_element?(lv, validation_input("pattern"))
      assert has_element?(lv, ~s|#new-field-validation input[type=number][step="1"]|)

      type_change(lv, "float")
      assert has_element?(lv, ~s|#new-field-validation input[type=number][step=any]|)

      type_change(lv, "date")
      assert has_element?(lv, validation_input("unique"))
      refute has_element?(lv, validation_input("min"))

      type_change(lv, "boolean")
      refute has_element?(lv, "#new-field-validation")

      # Rich text is HTML: no length. Plain text takes the text constraints,
      # but not unique.
      type_change(lv, "text")
      refute has_element?(lv, "#new-field-validation")

      lv
      |> element("#new-field-form")
      |> render_change(%{"field_definition" => %{"field_type" => "text", "format" => "plain"}})

      assert has_element?(lv, validation_input("max_length"))
      refute has_element?(lv, validation_input("unique"))
    end

    test "an admin saves constraints and sees them in the list", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "sku",
          label: "SKU",
          field_type: "string",
          validation: %{
            min_length: "3",
            max_length: "12",
            pattern: "[A-Z]+-[0-9]+",
            pattern_message: "Use LETTERS-123",
            unique: "true"
          }
        }
      )
      |> render_submit()

      field =
        :page |> CMS.field_definitions_for!(authorize?: false) |> Enum.find(&(&1.name == "sku"))

      assert field.validation == %{
               "min_length" => 3,
               "max_length" => 12,
               "pattern" => "[A-Z]+-[0-9]+",
               "pattern_message" => "Use LETTERS-123",
               "unique" => true
             }

      summary = lv |> element("#field-#{field.id}-validation") |> render()
      assert summary =~ "3 to 12 characters."
      assert summary =~ "Must match a pattern."
      assert summary =~ "Each value used once."

      # Blank inputs clear a constraint.
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{field.id}",
        field_definition: %{validation: %{min_length: "", max_length: "", pattern: ""}}
      )
      |> render_submit()

      field = CMS.get_field_definition!(field.id, authorize?: false)
      assert field.validation == %{"unique" => true}
    end

    test "numeric bounds are stored as numbers", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")
      type_change(lv, "integer")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "rating",
          label: "Rating",
          field_type: "integer",
          validation: %{min: "1", max: "5"}
        }
      )
      |> render_submit()

      field =
        :page
        |> CMS.field_definitions_for!(authorize?: false)
        |> Enum.find(&(&1.name == "rating"))

      assert field.validation == %{"min" => 1, "max" => 5}
    end

    test "changing the type drops the constraints it doesn't take", %{conn: conn} do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "code",
            label: "Code",
            field_type: :string,
            validation: %{"max_length" => 8, "pattern" => "[a-z]+", "unique" => true}
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      # The text constraints are posted by the string form; picking a number
      # type must not send them on.
      lv
      |> form("#edit-field-#{field.id}",
        field_definition: %{
          field_type: "integer",
          validation: %{max_length: "8", pattern: "[a-z]+", unique: "true"}
        }
      )
      |> render_submit()

      field = CMS.get_field_definition!(field.id, authorize?: false)
      assert field.field_type == :integer
      assert field.validation == %{"unique" => true}

      # To a type with no constraints at all.
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "boolean"})
      |> render_submit()

      assert CMS.get_field_definition!(field.id, authorize?: false).validation == %{}
    end

    test "a bad pattern is reported under the Pattern input", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            scopes: ["page"],
            name: "broken",
            label: "Broken",
            field_type: "string",
            validation: %{pattern: "([a-z"}
          }
        )
        |> render_submit()

      assert html =~ "pattern is not a valid regular expression"

      refute CMS.field_definitions_for!(:page, authorize?: false)
             |> Enum.any?(&(&1.name == "broken"))

      assert lv |> element("#new-field-validation") |> render() =~
               "pattern is not a valid regular expression"

      # The message sits with the pattern, not under the fieldset.
      refute has_element?(lv, "#new-field-validation > p[role=alert]")
    end

    test "min above max is reported as a general validation error", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      type_change(lv, "integer")

      html =
        lv
        |> form("#new-field-form",
          field_definition: %{
            scopes: ["page"],
            name: "inverted",
            label: "Inverted",
            field_type: "integer",
            validation: %{min: "9", max: "2"}
          }
        )
        |> render_submit()

      assert html =~ "min can&#39;t be more than max"
    end

    test "a group's sub-field form takes constraints, but not unique", %{conn: conn} do
      admin = authed_user(:admin)

      group =
        CMS.create_field_definition!(
          %{content_type: :page, name: "dosages", label: "Dosages", field_type: :group},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{group.id}-sub-fields-add") |> render_click()

      form_id = "#link-field-form-new-#{group.id}"
      assert has_element?(lv, form_id)
      assert has_element?(lv, ~s|#{form_id} [name="link_field[validation][max_length]"]|)
      refute has_element?(lv, ~s|#{form_id} [name="link_field[validation][unique]"]|)

      # A posted `unique` is dropped, as the form never offers it.
      lv
      |> element(form_id)
      |> render_submit(%{
        "link_field" => %{
          "label" => "Unit",
          "name" => "unit",
          "field_type" => "string",
          "validation" => %{"max_length" => "4", "unique" => "true"}
        }
      })

      assert [sub_id] = link_ids(group)

      assert CMS.get_field_definition!(sub_id, authorize?: false).validation == %{
               "max_length" => 4
             }
    end
  end

  # #2284: a choice of editor input, from what the field's settings offer.
  describe "the editor input" do
    defp widget_cards(lv, id \\ "new-field-widget") do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id} input[type=radio]")
      |> Enum.map(&LazyHTML.attribute(&1, "id"))
      |> List.flatten()
      |> Enum.map(&String.replace_prefix(&1, id <> "-", ""))
    end

    # Straight to the event: the inputs a change posts depend on the change.
    defp create_change(lv, params),
      do: lv |> element("#new-field-form") |> render_change(%{"field_definition" => params})

    test "offers the inputs each type takes, and none where there is no choice", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      type_change(lv, "select")
      assert widget_cards(lv) == ~w(dropdown radios buttons)
      assert lv |> element("label[for=new-field-widget-radios]") |> render() =~ "Radio buttons"
      # The default's card posts no widget: nil is "the type's default".
      assert has_element?(lv, "#new-field-widget-dropdown[value=''][checked]")

      create_change(lv, %{field_type: "select", multiple: "true"})
      assert widget_cards(lv) == ~w(tags checkboxes)

      create_change(lv, %{field_type: "text", format: "plain"})
      assert widget_cards(lv) == ~w(textarea single_line)
      assert lv |> element("label[for=new-field-widget-single_line]") |> render() =~ "One line"

      create_change(lv, %{field_type: "text", format: "rich"})
      refute has_element?(lv, "#new-field-widget")

      create_change(lv, %{kind: "relationship", field_type: "reference", multiple: "false"})
      assert widget_cards(lv) == ~w(autocomplete dropdown)

      assert lv |> element("label[for=new-field-widget-autocomplete]") |> render() =~
               "Search as you type"

      assert lv |> element("label[for=new-field-widget-dropdown]") |> render() =~ "Dropdown list"

      create_change(lv, %{kind: "relationship", field_type: "reference", multiple: "true"})
      refute has_element?(lv, "#new-field-widget")

      for type <- ~w(string integer boolean media date) do
        type_change(lv, type)
        refute has_element?(lv, "#new-field-widget"), "editor input offered for #{type}"
      end
    end

    # #2674: a line under the legend says the choice is editor-only.
    test "the cards are described as changing only how editors fill the field in", %{
      conn: conn
    } do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      type_change(lv, "select")

      assert has_element?(lv, "fieldset#new-field-widget[aria-describedby=new-field-widget-help]")

      assert lv |> element("#new-field-widget > p#new-field-widget-help") |> render() =~
               "How editors fill this in. What they enter is stored and delivered the same way."
    end

    # The page drops a widget its posted settings don't offer, so a refused
    # one with no cards left is rendered from a form validated directly.
    test "a refused input with no cards left shows the error without the help line" do
      form =
        FieldDefinition
        |> AshPhoenix.Form.for_create(:create,
          actor: authed_user(:admin),
          tenant: KilnCMS.Accounts.default_org_id(),
          as: "field_definition"
        )
        |> AshPhoenix.Form.validate(
          %{
            "content_type" => "page",
            "name" => "body_note",
            "label" => "Body note",
            "field_type" => "text",
            "format" => "rich",
            "widget" => "radios"
          },
          errors: true
        )
        |> Phoenix.Component.to_form()

      html =
        render_component(&KilnCMSWeb.FieldDefinitionLive.widget_field/1,
          form: form,
          id: "w"
        )

      fieldset = html |> LazyHTML.from_fragment() |> LazyHTML.query("fieldset#w")
      assert LazyHTML.text(fieldset) =~ "this field has no choice of editor input"
      refute html =~ "aria-describedby"
      refute html =~ "w-help"
      refute html =~ "stored and delivered"
    end

    test "a plugin type offers its own inputs, by its own labels", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      type_change(lv, "rating")
      assert widget_cards(lv) == ~w(number stars)
      assert lv |> element("label[for=new-field-widget-stars]") |> render() =~ "Stars"
      assert lv |> element("label[for=new-field-widget-number]") |> render() =~ "Number"
    end

    test "a chosen input is saved, badged in the list, and reset by the default's card", %{
      conn: conn
    } do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> element("#new-field-form")
      |> render_submit(%{
        "field_definition" => %{
          "scopes" => ["page"],
          "name" => "mood",
          "label" => "Mood",
          "field_type" => "select",
          "options" => "calm\nbright",
          "widget" => "radios"
        }
      })

      field =
        :page
        |> CMS.field_definitions_for!(authorize?: false)
        |> Enum.find(&(&1.name == "mood"))

      assert field.widget == "radios"
      assert lv |> element("#field-#{field.id}-widget") |> render() =~ "Radio buttons"

      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-widget-#{field.id}-radios[checked]")

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{widget: ""})
      |> render_submit()

      assert CMS.get_field_definition!(field.id, authorize?: false).widget == nil
      refute has_element?(lv, "#field-#{field.id}-widget")
    end

    test "a retype drops the cards and the stored input with them", %{conn: conn} do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "mood",
            label: "Mood",
            field_type: :select,
            options: ["calm", "bright"],
            widget: "buttons"
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      id = "edit-field-widget-#{field.id}"
      assert widget_cards(lv, id) == ~w(dropdown radios buttons)

      lv
      |> element("#edit-field-#{field.id}")
      |> render_change(%{"field_definition" => %{"field_type" => "text", "format" => "plain"}})

      assert widget_cards(lv, id) == ~w(textarea single_line)
      # The stored widget isn't one of these: the default's card is checked.
      assert has_element?(lv, "##{id}-textarea[checked]")

      # A card from before the retype, still posted, is dropped, not refused.
      lv
      |> element("#edit-field-#{field.id}")
      |> render_submit(%{
        "field_definition" => %{
          "field_type" => "text",
          "format" => "plain",
          "widget" => "buttons"
        }
      })

      saved = CMS.get_field_definition!(field.id, authorize?: false)
      assert saved.field_type == :text
      assert saved.widget == nil
    end

    test "checkboxes and editors' own terms exclude each other, saying why", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      create_change(lv, %{field_type: "select", multiple: "true", allow_custom: "true"})
      assert has_element?(lv, "#new-field-widget-checkboxes[disabled]")
      assert lv |> element("#new-field-widget-checkboxes-conflict") |> render() =~ "new terms"

      create_change(lv, %{
        field_type: "select",
        multiple: "true",
        allow_custom: "false",
        widget: "checkboxes"
      })

      refute has_element?(lv, "#new-field-widget-checkboxes[disabled]")
      assert has_element?(lv, "#new-field-widget-checkboxes[checked]")
      assert has_element?(lv, "#new-field-multiple-allow-custom[disabled]")
      assert lv |> element("#new-field-multiple-allow-custom-conflict") |> render() =~ "Tags"
    end

    test "a per-option input warns when the field lists too many options", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")
      cap = KilnCMS.CMS.FieldWidgets.option_cap()

      create_change(lv, %{field_type: "select", options: Enum.map_join(1..cap, "\n", &"o#{&1}")})
      refute has_element?(lv, "#new-field-widget-radios-cap")

      options = Enum.map_join(1..(cap + 1), "\n", &"o#{&1}")
      create_change(lv, %{field_type: "select", options: options})
      assert lv |> element("#new-field-widget-radios-cap") |> render() =~ "dropdown instead"
      assert has_element?(lv, "#new-field-widget-buttons-cap")
      refute has_element?(lv, "#new-field-widget-dropdown-cap")

      create_change(lv, %{field_type: "select", multiple: "true", options: options})
      assert lv |> element("#new-field-widget-checkboxes-cap") |> render() =~ "tags instead"
    end
  end

  describe "scalar lists (#2289)" do
    @list_radio "#new-field-form input[name='field_definition[multiple]'][value=true]"

    test "a number, date, link or address asks one value or a list; a boolean or JSON does not",
         %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      for type <- ~w(integer date url email) do
        html = type_change(lv, type)
        assert has_element?(lv, @list_radio), type
        assert html =~ "One value"
        assert html =~ "As many values as the editor adds"
      end

      for type <- ~w(boolean json) do
        type_change(lv, type)
        refute has_element?(lv, @list_radio), type
      end
    end

    test "a list of dates keeps its bounds, is badged, and warns before narrowing back", %{
      conn: conn
    } do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/fields")

      type_change(lv, "date")

      lv
      |> form("#new-field-form", field_definition: %{multiple: "true"})
      |> render_change()

      assert has_element?(lv, "#new-field-multiple-bounds")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "event_dates",
          label: "Event dates",
          field_type: "date",
          multiple: "true",
          min_items: "1",
          max_items: "10"
        }
      )
      |> render_submit()

      field =
        :page
        |> CMS.field_definitions_for!(authorize?: false)
        |> Enum.find(&(&1.name == "event_dates"))

      assert {field.multiple, field.min_items, field.max_items} == {true, 1, 10}
      assert lv |> element("#field-#{field.id}") |> render() =~ "list"

      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
      refute has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{multiple: "false"})
      |> render_change()

      assert lv |> element("#edit-field-multiple-#{field.id}-narrowing") |> render() =~
               "Saving keeps only the first item of each list already filled in."
    end

    test "retyping a list into another list says the items are kept, not narrowed", %{
      conn: conn
    } do
      admin = authed_user(:admin)

      field =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "codes",
            label: "Codes",
            field_type: :string,
            multiple: true
          },
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "date"})
      |> render_change()

      assert has_element?(lv, "#edit-field-multiple-#{field.id}-retyped")
      refute has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")

      # Retyped to a type that holds no list, the list narrows.
      lv
      |> form("#edit-field-#{field.id}", field_definition: %{field_type: "boolean"})
      |> render_change()

      assert has_element?(lv, "#edit-field-multiple-#{field.id}-narrowing")
      refute has_element?(lv, "#edit-field-multiple-#{field.id}-retyped")
    end

    test "making a field a list warns when a formula reads it", %{conn: conn} do
      admin = authed_user(:admin)

      doses =
        CMS.create_field_definition!(
          %{content_type: :page, name: "doses", label: "Doses", field_type: :integer},
          actor: admin
        )

      plain =
        CMS.create_field_definition!(
          %{content_type: :page, name: "steps", label: "Steps", field_type: :integer},
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "total_dose",
          label: "Total dose",
          field_type: :computed,
          compute: "{{ sum(field.doses, 1) }}"
        },
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv |> element("#field-#{doses.id} button[phx-click=edit]") |> render_click()
      refute has_element?(lv, "#edit-field-multiple-#{doses.id}-formulas")

      lv
      |> form("#edit-field-#{doses.id}", field_definition: %{multiple: "true"})
      |> render_change()

      assert lv |> element("#edit-field-multiple-#{doses.id}-formulas") |> render() =~
               "Total dose"

      lv |> element("#edit-field-#{doses.id} button", "Cancel") |> render_click()
      lv |> element("#field-#{plain.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{plain.id}", field_definition: %{multiple: "true"})
      |> render_change()

      refute has_element?(lv, "#edit-field-multiple-#{plain.id}-formulas")
    end

    test "a group's sub-field form never asks for a list", %{conn: conn} do
      admin = authed_user(:admin)

      group =
        CMS.create_field_definition!(
          %{content_type: :page, name: "sessions", label: "Sessions", field_type: :group},
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      lv |> element("#field-#{group.id}-sub-fields-add") |> render_click()

      form_id = "#link-field-form-new-#{group.id}"

      lv
      |> element(form_id)
      |> render_change(%{"link_field" => %{"field_type" => "date"}})

      refute has_element?(lv, ~s|#{form_id} [name="link_field[multiple]"]|)
    end
  end

  defp link_ids(group) do
    group
    |> Ash.load!(:group_fields, authorize?: false)
    |> Map.fetch!(:group_fields)
    |> Enum.map(& &1.id)
  end
end
