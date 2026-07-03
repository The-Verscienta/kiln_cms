defmodule KilnCMSWeb.PluginFieldTypeTest do
  @moduledoc """
  Plugin custom field types in the admin UIs (D18): the fields admin offers
  the fixture plugin's `Rating` type under its own label, and the content
  editor renders the field with the plugin's input kind + attributes.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "pft-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "the fields admin offers the plugin type with its label", %{conn: conn} do
    admin = authed_admin()

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/fields")

    assert html =~ ~s(value="rating")
    assert html =~ "Rating"
  end

  test "the content editor renders the plugin's input kind and attributes", %{conn: conn} do
    admin = authed_admin()

    field =
      CMS.create_field_definition!(
        %{content_type: :page, name: "stars", label: "Stars", field_type: :rating},
        actor: admin
      )

    page =
      CMS.create_page!(
        %{
          title: "Rated page",
          slug: "pft-#{System.unique_integer([:positive])}",
          custom_fields: %{"stars" => 3}
        },
        actor: admin
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    assert [input_tag] =
             Regex.run(~r/<input[^>]*id="custom-field-#{field.name}"[^>]*>/, html)

    assert input_tag =~ ~s(type="number")
    assert input_tag =~ ~s(min="1")
    assert input_tag =~ ~s(max="5")
    assert input_tag =~ ~s(value="3")
  end
end
