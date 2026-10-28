defmodule KilnCMSWeb.FieldSectionsTest do
  @moduledoc """
  Sections in the content editor's Custom fields panel (`section` on a
  `FieldDefinition`): fields sharing a section sit under one collapsible
  heading at the place of its first field, a section holding a stored value
  (or the first one, on a record with none) starts open, a collapsed
  section's inputs still submit, and the fields admin sets the section.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.ContentEditor.CustomFieldsPanel

  @password "password123456"

  defp authed_admin do
    email = "sections-#{System.unique_integer([:positive])}@example.com"

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

  defp define!(admin, name, position, section) do
    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: name,
        label: String.capitalize(name),
        field_type: :string,
        position: position,
        section: section
      },
      actor: admin
    )
  end

  defp signed_in(conn, admin) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
  end

  describe "sections/1" do
    test "groups by section at its first field's place; unsectioned runs stay put" do
      defs =
        for {name, section} <- [
              {"a", nil},
              {"b", "Identity"},
              {"c", "Safety"},
              {"d", "Identity"},
              {"e", nil}
            ],
            do: %{name: name, section: section}

      assert [
               {nil, [%{name: "a"}], 0},
               {"Identity", [%{name: "b"}, %{name: "d"}], 1},
               {"Safety", [%{name: "c"}], 2},
               {nil, [%{name: "e"}], 3}
             ] = CustomFieldsPanel.sections(defs)
    end
  end

  test "a group sub-field and a link field carry no section" do
    admin = authed_admin()

    group =
      CMS.create_field_definition!(
        %{content_type: :page, name: "doses", label: "Doses", field_type: :group},
        actor: admin
      )

    sub =
      CMS.create_field_definition!(
        %{group_of_id: group.id, name: "unit", label: "Unit", section: "Safety"},
        actor: admin
      )

    assert sub.section == nil
  end

  describe "the editor panel" do
    setup %{conn: conn} do
      admin = authed_admin()
      define!(admin, "intro", 0, nil)
      define!(admin, "latin", 1, "Identity")
      define!(admin, "pinyin", 2, "Identity")
      define!(admin, "caution", 3, "Safety")
      define!(admin, "dose", 4, "Dosing")

      page =
        CMS.create_page!(
          %{
            title: "Ginseng",
            slug: "sections-#{System.unique_integer([:positive])}",
            custom_fields: %{"latin" => "Panax ginseng", "caution" => "Pregnancy"}
          },
          actor: admin
        )

      {:ok, lv, _html} = live(signed_in(conn, admin), ~p"/editor/content/page/#{page.id}")
      %{admin: admin, page: page, lv: lv, conn: conn}
    end

    test "files fields under their headings, with a count of what is filled", ctx do
      assert has_element?(ctx.lv, "#custom-fields #custom-field-intro")
      refute has_element?(ctx.lv, "[id^=cf-section-] #custom-field-intro")

      assert has_element?(ctx.lv, "#cf-section-1-heading", "Identity")
      assert has_element?(ctx.lv, "#cf-section-1-body #custom-field-latin")
      assert has_element?(ctx.lv, "#cf-section-1-body #custom-field-pinyin")
      assert has_element?(ctx.lv, "#cf-section-1-toggle", "1 of 2 filled")

      assert has_element?(ctx.lv, "#cf-section-2-heading", "Safety")
      assert has_element?(ctx.lv, "#cf-section-3-heading", "Dosing")
      assert has_element?(ctx.lv, "#cf-sections-expand")
      assert has_element?(ctx.lv, "#cf-sections-collapse")
    end

    test "a section holding a stored value starts open; the others start closed", ctx do
      assert has_element?(ctx.lv, ~s(#cf-section-1-toggle[aria-expanded="true"]))
      refute has_element?(ctx.lv, "#cf-section-1-body.hidden")

      assert has_element?(ctx.lv, ~s(#cf-section-3-toggle[aria-expanded="false"]))
      assert has_element?(ctx.lv, "#cf-section-3-body.hidden")
    end

    test "a closed section's inputs still submit", ctx do
      ctx.lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"dose" => "3 g"}}})
      |> render_submit()

      fields = CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields
      assert fields["dose"] == "3 g"
      assert fields["latin"] == "Panax ginseng"
    end
  end

  test "on a record with nothing stored, the first section starts open", %{conn: conn} do
    admin = authed_admin()
    define!(admin, "latin", 0, "Identity")
    define!(admin, "caution", 1, "Safety")

    page =
      CMS.create_page!(
        %{title: "Empty", slug: "sections-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    {:ok, lv, _html} = live(signed_in(conn, admin), ~p"/editor/content/page/#{page.id}")

    assert has_element?(lv, ~s(#cf-section-0-toggle[aria-expanded="true"]))
    assert has_element?(lv, ~s(#cf-section-1-toggle[aria-expanded="false"]))
  end

  test "the fields admin sets a field's section and suggests those in use", %{conn: conn} do
    admin = authed_admin()
    define!(admin, "latin", 0, "Identity")

    {:ok, lv, _html} = live(signed_in(conn, admin), ~p"/editor/fields")

    assert has_element?(lv, ~s(datalist option[value="Identity"]))

    lv
    |> form("#new-field-form",
      field_definition: %{
        scopes: ["page"],
        name: "pinyin",
        label: "Pinyin",
        field_type: "string",
        section: "  Identity "
      }
    )
    |> render_submit()

    field =
      :page
      |> CMS.field_definitions_for!(authorize?: false)
      |> Enum.find(&(&1.name == "pinyin"))

    assert field.section == "Identity"
    assert has_element?(lv, "#field-#{field.id}-section", "Identity")
  end
end
