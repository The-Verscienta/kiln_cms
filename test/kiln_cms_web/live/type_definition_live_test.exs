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

  test "an admin creates a dynamic content type through the UI", %{conn: conn} do
    admin = authed_user(:admin)
    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/types")

    assert html =~ "Content types"

    name = "recipe#{System.unique_integer([:positive])}"

    lv
    |> form("#new-type-form", type_definition: %{name: name, label: "Recipe"})
    |> render_submit()

    html = render(lv)
    assert html =~ "Recipe"
    assert html =~ name

    definition = CMS.get_type_definition_by_name!(name, authorize?: false)
    assert definition.path_segment == name <> "s"
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
        scope: "def:#{definition.id}",
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
