defmodule KilnCMSWeb.FieldDefinitionLiveTest do
  @moduledoc """
  The admin custom-fields UI (`/editor/fields`): admins define typed fields per
  content type, and the content editor then renders an input per definition.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

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
        content_type: "page",
        name: "toxicity_level",
        label: "Toxicity",
        field_type: "string"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Toxicity"
    assert html =~ "toxicity_level"

    assert :page
           |> CMS.field_definitions_for!(authorize?: false)
           |> Enum.any?(&(&1.name == "toxicity_level"))
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
        name: "toxicity_level",
        label: "Toxicity level",
        field_type: :string
      },
      actor: admin
    )

    page =
      CMS.create_page!(%{title: "Herb", slug: "fd-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/pages/#{page.id}")

    assert html =~ "Custom fields"
    assert html =~ "Toxicity level"
    assert html =~ "custom_fields][toxicity_level]"
  end
end
