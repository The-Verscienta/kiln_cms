defmodule KilnCMSWeb.FlexibleFieldsAdminTest do
  @moduledoc """
  A `:flexible` field (#2282) is API-only until its item-types panel ships:
  the fields admin (`/editor/fields`) lists the field but neither its item
  types nor their sub-fields (they are not fields of a type, and are not link
  fields), and does not offer the type in the new-field form.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "flexa-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "lists the flexible field, not its item types, and does not offer the type", %{conn: conn} do
    admin = authed_admin()
    name = "sections_#{System.unique_integer([:positive])}"

    flexible =
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: "Sections", field_type: :flexible},
        actor: admin
      )

    item =
      CMS.create_field_definition!(
        %{
          name: "uniqueitemtype",
          label: "Unique Item Type",
          field_type: :group,
          flex_of_id: flexible.id
        },
        actor: admin
      )

    CMS.create_field_definition!(
      %{
        name: "uniquesubfield",
        label: "Unique Sub Field",
        field_type: :string,
        group_of_id: item.id
      },
      actor: admin
    )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, html} = live(conn, ~p"/editor/fields")

    assert has_element?(lv, "#field-#{flexible.id}")
    refute html =~ "Unique Item Type"
    refute html =~ "Unique Sub Field"

    refute has_element?(lv, "#new-field-form select option[value=flexible]")
    assert has_element?(lv, "#new-field-form select option[value=group]")
  end
end
