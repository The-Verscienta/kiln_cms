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
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

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

  test "non-admins are redirected away", %{conn: conn} do
    editor = authed_user(:editor)
    assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in(editor) |> live(~p"/editor/fields")
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
    # conditional treatment `target_type` gets for `:reference`.
    form = form(lv, "#new-field-form", field_definition: %{field_type: "computed"})
    assert render_change(form) =~ "Formula"

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

      for type <- ~w(media reference computed geolocation datetime_range recurrence) do
        type_change(lv, type)
        refute has_element?(lv, default), "default shown for #{type}"
      end

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
end
