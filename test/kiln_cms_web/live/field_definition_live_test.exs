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

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/pages/#{page.id}")

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

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/pages/#{page.id}")

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

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/pages/#{page.id}")

    assert html =~ "URL key"
    assert html =~ "readonly"
    assert html =~ "first-title"

    # Retyping the title recomputes it in place, without a save.
    html = render_change(form(lv, "#page-editor"), %{"form" => %{"title" => "Second Title"}})

    assert html =~ "second-title"
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

  defp label_change(lv, label, name) do
    lv
    |> form("#new-field-form")
    |> render_change(%{
      "_target" => ["field_definition", "label"],
      "field_definition" => %{"label" => label, "name" => name}
    })
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
