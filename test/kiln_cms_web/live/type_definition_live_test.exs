defmodule KilnCMSWeb.TypeDefinitionLiveTest do
  @moduledoc """
  The admin content-types UI (`/editor/types`): admins define dynamic content
  types (decision D17); their fields are then managed on `/editor/fields`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "td-#{System.unique_integer([:positive])}@example.com"

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

  # #1773 (WCAG 2.4.2): the heading said "Content types" but the browser tab
  # said only "KilnCMS" — the page never assigned :page_title.
  test "the page has a descriptive document title", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/types")
    assert page_title(lv) =~ "Content types"
  end

  test "an admin creates a dynamic content type through the UI", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/types")

    assert html =~ "Content types"

    name = "recipe#{System.unique_integer([:positive])}"

    lv
    |> form("#new-type-form", type_definition: %{name: name, label: "Recipe"})
    |> render_submit()
    |> follow_redirect(conn)

    definition = CMS.get_type_definition_by_name!(name, authorize?: false)
    assert definition.path_segment == name <> "s"

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/types")
    assert html =~ "Recipe"
    assert html =~ name
  end

  # #1817: a new type has no fields, so its authors have nothing to fill in
  # until it does — creating one goes straight to its fields, type ticked.
  test "creating a type goes on to the fields page with the type ticked", %{conn: conn} do
    admin = authed_user(:admin)
    conn = log_in(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/editor/types")
    name = "dish#{System.unique_integer([:positive])}"

    result =
      lv
      |> form("#new-type-form", type_definition: %{name: name, label: "Dish"})
      |> render_submit()

    definition = CMS.get_type_definition_by_name!(name, authorize?: false)
    to = ~p"/editor/fields?#{[type: "def:#{definition.id}"]}"
    assert {:error, {:live_redirect, %{to: ^to}}} = result

    {:ok, fields, html} = follow_redirect(result, conn)
    assert html =~ "Content type created. Now add its fields."

    assert has_element?(
             fields,
             ~s|#new-field-form input[type=checkbox][value="def:#{definition.id}"][checked]|
           )

    # The type list links each type to its own fields the same way.
    {:ok, types, _html} = live(conn, ~p"/editor/types")
    assert has_element?(types, ~s|#type-#{definition.id} a[href="#{to}"]|)
  end

  # #1816: the URL segment was filled from the machine name once, then the
  # filled value came back as if typed — a typo fixed in the machine name
  # stayed in the URL.
  describe "the URL segment" do
    test "follows the machine name until the admin edits it", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/types")

      name_change(lv, "recpie", "")
      assert segment_value(lv) == "recpies"

      # Correcting the machine name corrects the segment with it.
      name_change(lv, "recipe", "recpies")
      assert segment_value(lv) == "recipes"

      # Typing into the segment takes it over.
      lv
      |> form("#new-type-form")
      |> render_change(%{
        "_target" => ["type_definition", "path_segment"],
        "type_definition" => %{"name" => "recipe", "path_segment" => "dishes"}
      })

      name_change(lv, "recipes_v2", "dishes")
      assert segment_value(lv) == "dishes"

      # Clearing the segment hands it back to the machine name.
      lv
      |> form("#new-type-form")
      |> render_change(%{
        "_target" => ["type_definition", "path_segment"],
        "type_definition" => %{"name" => "recipes_v2", "path_segment" => ""}
      })

      name_change(lv, "meal", "")
      assert segment_value(lv) == "meals"
    end

    test "an edited segment is the one saved", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/types")
      name = "seg#{System.unique_integer([:positive])}"

      lv
      |> form("#new-type-form")
      |> render_change(%{
        "_target" => ["type_definition", "path_segment"],
        "type_definition" => %{"name" => name, "path_segment" => "custom-seg"}
      })

      lv
      |> form("#new-type-form",
        type_definition: %{name: name, label: "Seg", path_segment: "custom-seg"}
      )
      |> render_submit()

      assert CMS.get_type_definition_by_name!(name, authorize?: false).path_segment ==
               "custom-seg"
    end
  end

  defp name_change(lv, name, segment) do
    lv
    |> form("#new-type-form")
    |> render_change(%{
      "_target" => ["type_definition", "name"],
      "type_definition" => %{"name" => name, "path_segment" => segment}
    })
  end

  defp segment_value(lv) do
    lv
    |> element(~s|#new-type-form input[name="type_definition[path_segment]"]|)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> List.first()
  end

  test "collision with a built-in type is rejected with an error", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/types")

    html =
      lv
      |> form("#new-type-form", type_definition: %{name: "page", label: "Page again"})
      |> render_submit()

    assert html =~ "already used"
  end

  test "archiving and restoring a type", %{conn: conn} do
    admin = authed_user(:admin)

    definition =
      CMS.create_type_definition!(
        %{name: "arch#{System.unique_integer([:positive])}", label: "Archivable"},
        actor: admin
      )

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/types")

    lv |> element("#type-#{definition.id} button[phx-click=archive]") |> render_click()

    html = render(lv)
    assert html =~ "Archived types"

    lv |> element("#archived-type-#{definition.id} button[phx-click=restore]") |> render_click()

    refute render(lv) =~ "Archived types"
    assert CMS.get_type_definition!(definition.id, actor: admin)
  end

  test "non-admins are redirected away", %{conn: conn} do
    editor = authed_user(:editor)
    assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in(editor) |> live(~p"/editor/types")
  end

  test "a dynamic type is offered as a scope on the custom-fields page", %{conn: conn} do
    admin = authed_user(:admin)

    definition =
      CMS.create_type_definition!(
        %{name: "sc#{System.unique_integer([:positive])}", label: "Scoped"},
        actor: admin
      )

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    assert html =~ "def:#{definition.id}"

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["def:#{definition.id}"],
        name: "servings",
        label: "Servings",
        field_type: "integer"
      }
    )
    |> render_submit()

    assert render(lv) =~ "Servings"

    assert definition.id
           |> CMS.field_definitions_for_definition!(authorize?: false)
           |> Enum.any?(&(&1.name == "servings"))
  end
end
