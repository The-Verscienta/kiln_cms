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
        scope: "page",
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
        scope: "page",
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
          scope: "page",
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
end
