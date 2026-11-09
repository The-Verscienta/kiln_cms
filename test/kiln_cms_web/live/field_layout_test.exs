defmodule KilnCMSWeb.FieldLayoutTest do
  @moduledoc """
  Section layouts and field width in the content editor's Custom fields panel
  (#2280): a section laid out as a fieldset or a tab instead of the default
  accordion, an accordion's `initially` overriding the open heuristic, the
  one tab set gathering every `:tab` section, and a narrow field putting its
  group on a grid. A type with no layout renders as before
  (`KilnCMSWeb.FieldSectionsTest`).
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.ContentEditor.CustomFieldsPanel

  @password "password123456"

  defp user(role) do
    email = "layout-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
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

  defp field!(admin, name, position, section, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: name,
          label: String.capitalize(name),
          field_type: :string,
          position: position,
          section: section
        },
        attrs
      ),
      actor: admin
    )
  end

  defp layout!(admin, name, attrs),
    do:
      CMS.create_field_section!(Map.merge(%{content_type: :page, name: name}, attrs),
        actor: admin
      )

  defp open(conn, user, admin, fields \\ %{}) do
    page =
      CMS.create_page!(
        %{
          title: "Layout",
          slug: "layout-#{System.unique_integer([:positive])}",
          custom_fields: fields
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    {lv, page}
  end

  defp attr(lv, selector, name) do
    lv |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.attribute(name)
  end

  defp classes(lv, selector), do: attr(lv, selector, "class") |> List.first() |> String.split()

  describe "layout/2" do
    test "gathers every tab section into one tab set at the first one's place" do
      defs =
        for {name, section} <- [
              {"a", nil},
              {"b", "One"},
              {"c", "Open"},
              {"d", "Two"},
              {"e", "Box"}
            ],
            do: %{name: name, section: section}

      rows = [
        %{name: "One", display: :tab, initially: :auto},
        %{name: "Two", display: :tab, initially: :auto},
        %{name: "Box", display: :fieldset, initially: :auto},
        %{name: "Open", display: :accordion, initially: :expanded}
      ]

      assert [
               %{display: :none, index: 0},
               %{display: :tabs, index: 1, tabs: [%{name: "One"}, %{name: "Two", index: 3}]},
               %{display: :accordion, name: "Open", index: 2, initially: :expanded},
               %{display: :fieldset, name: "Box", index: 4}
             ] = CustomFieldsPanel.layout(defs, rows)
    end

    test "with no layout rows every section is an auto accordion" do
      defs = [%{name: "a", section: "One"}, %{name: "b", section: nil}]

      assert [
               %{display: :accordion, name: "One", initially: :auto},
               %{display: :none, name: nil}
             ] = CustomFieldsPanel.layout(defs, [])
    end
  end

  describe "a fieldset" do
    setup do
      admin = user(:admin)
      field!(admin, "latin", 0, "Identity")
      field!(admin, "pinyin", 1, "Identity")
      layout!(admin, "Identity", %{display: :fieldset, initially: :collapsed})
      %{admin: admin}
    end

    test "is a fieldset with a legend, always open, with no toggle", ctx do
      {lv, _page} = open(build_conn(), ctx.admin, ctx.admin)

      assert has_element?(lv, "fieldset#cf-section-0 > legend#cf-section-0-heading", "Identity")
      assert has_element?(lv, "fieldset#cf-section-0 #custom-field-latin")
      assert has_element?(lv, "fieldset#cf-section-0 #custom-field-pinyin")
      refute has_element?(lv, "#cf-section-0-toggle")
      refute has_element?(lv, "#cf-section-0 [data-cf-section-body]")
      refute has_element?(lv, "#cf-section-0 .hidden")

      # Nothing to expand or collapse without an accordion.
      refute has_element?(lv, "#cf-sections-expand")
      refute has_element?(lv, "#cf-sections-collapse")
    end

    test "is laid out for an editor too, who reads the layout as themselves", ctx do
      {lv, _page} = open(build_conn(), user(:editor), ctx.admin)

      assert has_element?(lv, "fieldset#cf-section-0 > legend", "Identity")
    end
  end

  describe "an accordion's initially" do
    setup do
      admin = user(:admin)
      field!(admin, "latin", 0, "Identity")
      field!(admin, "caution", 1, "Safety")
      field!(admin, "dose", 2, "Dosing")
      %{admin: admin}
    end

    test ":collapsed closes a section holding a value; :expanded opens an empty one", ctx do
      layout!(ctx.admin, "Identity", %{initially: :collapsed})
      layout!(ctx.admin, "Dosing", %{initially: :expanded})
      {lv, _page} = open(build_conn(), ctx.admin, ctx.admin, %{"latin" => "Panax"})

      assert has_element?(lv, ~s(#cf-section-0-toggle[aria-expanded="false"]))
      assert has_element?(lv, "#cf-section-0-body.hidden")

      # Auto: holds nothing, and another section holds a value — closed.
      assert has_element?(lv, ~s(#cf-section-1-toggle[aria-expanded="false"]))

      assert has_element?(lv, ~s(#cf-section-2-toggle[aria-expanded="true"]))
      refute has_element?(lv, "#cf-section-2-body.hidden")

      assert has_element?(lv, "#cf-sections-expand")
    end

    test "a collapsed section holding an error opens anyway", ctx do
      CMS.update_field_definition!(
        Enum.find(CMS.field_definitions_for!(:page, actor: ctx.admin), &(&1.name == "dose")),
        %{required: true},
        actor: ctx.admin
      )

      layout!(ctx.admin, "Dosing", %{initially: :collapsed})
      {lv, _page} = open(build_conn(), ctx.admin, ctx.admin, %{"dose" => "3 g"})
      assert has_element?(lv, "#cf-section-2-body.hidden")

      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"dose" => ""}}})
      |> render_submit()

      assert has_element?(lv, "#custom-field-dose-errors")
      assert has_element?(lv, ~s(#cf-section-2-toggle[aria-expanded="true"]))
      refute has_element?(lv, "#cf-section-2-body.hidden")
    end
  end

  describe "tabs" do
    setup do
      admin = user(:admin)
      field!(admin, "intro", 0, nil)
      field!(admin, "latin", 1, "Identity")
      field!(admin, "caution", 2, "Notes")
      field!(admin, "dose", 3, "Dosing", %{required: true})
      layout!(admin, "Identity", %{display: :tab})
      layout!(admin, "Dosing", %{display: :tab})
      %{admin: admin}
    end

    test "render one WAI-ARIA tab set at the first tab section's place", ctx do
      {lv, _page} = open(build_conn(), ctx.admin, ctx.admin, %{"dose" => "3 g"})

      assert ["tablist"] = attr(lv, "#cf-tabs-list", "role")
      assert ["TabKeys"] = attr(lv, "#cf-tabs-list", "phx-hook")
      assert ["custom-fields-heading"] = attr(lv, "#cf-tabs-list", "aria-labelledby")

      assert ["tab"] = attr(lv, "#cf-section-1-tab", "role")
      assert ["true"] = attr(lv, "#cf-section-1-tab", "aria-selected")
      assert ["0"] = attr(lv, "#cf-section-1-tab", "tabindex")
      assert ["cf-section-1-panel"] = attr(lv, "#cf-section-1-tab", "aria-controls")
      assert has_element?(lv, "#cf-section-1-tab", "Identity")

      assert ["false"] = attr(lv, "#cf-section-3-tab", "aria-selected")
      assert ["-1"] = attr(lv, "#cf-section-3-tab", "tabindex")
      assert has_element?(lv, "#cf-section-3-tab", "Dosing")

      assert ["tabpanel"] = attr(lv, "#cf-section-3-panel", "role")
      assert ["cf-section-3-tab"] = attr(lv, "#cf-section-3-panel", "aria-labelledby")
      refute "hidden" in classes(lv, "#cf-section-1-panel")
      assert "hidden" in classes(lv, "#cf-section-3-panel")
      # The hidden panel keeps its input.
      assert has_element?(lv, "#cf-section-3-panel #custom-field-dose")
      refute has_element?(lv, "#cf-tabs [data-cf-section-body]")

      # One tab set, before the accordion that sits between the two tabs.
      assert [_] =
               lv
               |> render()
               |> Floki.parse_document!()
               |> Floki.find("[role=tablist]#cf-tabs-list")

      html = render(lv)
      {tabs_at, _} = :binary.match(html, ~s(id="cf-tabs"))
      {notes_at, _} = :binary.match(html, ~s(id="cf-section-2"))
      {intro_at, _} = :binary.match(html, ~s(id="custom-field-intro"))
      assert intro_at < tabs_at and tabs_at < notes_at

      # The Notes accordion is still there, so Expand/Collapse all are too.
      assert has_element?(lv, "#cf-section-2-toggle")
      assert has_element?(lv, "#cf-sections-expand")
    end

    test "a hidden tab's input still submits", ctx do
      {lv, page} = open(build_conn(), ctx.admin, ctx.admin, %{"dose" => "3 g"})

      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"dose" => "5 g"}}})
      |> render_submit()

      assert CMS.get_page!(page.id, authorize?: false).custom_fields["dose"] == "5 g"
    end

    test "after a refused save the first tab holding an error is selected and marked", ctx do
      {lv, _page} = open(build_conn(), ctx.admin, ctx.admin, %{"dose" => "3 g"})
      assert ["true"] = attr(lv, "#cf-section-1-tab", "aria-selected")
      refute has_element?(lv, "#cf-section-3-tab .hero-exclamation-circle")

      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"dose" => ""}}})
      |> render_submit()

      assert has_element?(lv, "#custom-field-dose-errors")
      assert ["true"] = attr(lv, "#cf-section-3-tab", "aria-selected")
      assert ["0"] = attr(lv, "#cf-section-3-tab", "tabindex")
      assert ["false"] = attr(lv, "#cf-section-1-tab", "aria-selected")
      refute "hidden" in classes(lv, "#cf-section-3-panel")
      assert "hidden" in classes(lv, "#cf-section-1-panel")
      assert has_element?(lv, "#cf-section-3-tab .hero-exclamation-circle")
      assert has_element?(lv, "#cf-section-3-tab .sr-only", "Needs attention")
      refute has_element?(lv, "#cf-section-1-tab .hero-exclamation-circle")
    end
  end

  describe "width" do
    test "a narrow field puts its group on a six-column grid with a cell per field" do
      admin = user(:admin)
      field!(admin, "latin", 0, "Identity", %{width: :half})
      field!(admin, "pinyin", 1, "Identity", %{width: :third})
      field!(admin, "notes", 2, "Identity")
      field!(admin, "caution", 3, "Safety")
      {lv, _page} = open(build_conn(), admin, admin)

      assert has_element?(lv, "#cf-section-0-body > .grid.sm\\:grid-cols-6 > #cf-cell-latin")
      assert "sm:col-span-3" in classes(lv, "#cf-cell-latin")
      assert "sm:col-span-2" in classes(lv, "#cf-cell-pinyin")
      assert "sm:col-span-6" in classes(lv, "#cf-cell-notes")
      assert has_element?(lv, "#cf-cell-latin #custom-field-latin")

      # A group of full-width fields keeps its bare rows.
      refute has_element?(lv, "#cf-cell-caution")
      refute has_element?(lv, "#cf-section-1-body .grid")
    end

    test "a hidden conditional field's cell hides with it" do
      admin = user(:admin)
      rule = %{"field" => "kind", "op" => "eq", "value" => "other"}

      field!(admin, "kind", 0, nil, %{
        field_type: :select,
        options: ["a", "other"],
        width: :half
      })

      field!(admin, "detail", 1, nil, %{visible_when: rule, width: :half})
      {lv, _page} = open(build_conn(), admin, admin, %{"kind" => "a"})

      # The cell collapses whenever its direct child (the FieldConditions
      # wrapper) is hidden — server-seeded here, toggled by the hook later.
      assert "has-[>.hidden]:hidden" in classes(lv, "#cf-cell-detail")
      assert has_element?(lv, "#cf-cell-detail > #cf-cond-detail.hidden")
    end
  end
end
