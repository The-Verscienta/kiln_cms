defmodule KilnCMSWeb.CompositeFieldInvalidTest do
  @moduledoc """
  A composite custom field that fails validation must keep showing what was
  typed. It is absent from the cleaned map `ApplyCustomFields` writes back, so
  the editor used to render every part blank once the record held a stored
  value, and the next change event posted the blanks.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "cfi-#{System.unique_integer([:positive])}@example.com"

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

  test "typed parts stay visible while the composite value is invalid", %{conn: conn} do
    admin = authed_admin()

    CMS.create_field_definition!(
      %{content_type: :page, name: "spot", label: "Spot", field_type: :geolocation},
      actor: admin
    )

    page =
      CMS.create_page!(
        %{
          title: "Located",
          slug: "cfi-#{System.unique_integer([:positive])}",
          custom_fields: %{"spot" => %{"lat" => "10", "lng" => "20"}}
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")

    html =
      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"spot" => %{"lng" => "999"}}}})
      |> render_change()

    assert html =~ "must be between"
    assert html =~ ~r/id="custom-field-spot-lat"[^>]*value="10(?:\.0)?"/
    assert html =~ ~r/id="custom-field-spot-lng"[^>]*value="999"/
  end
end
