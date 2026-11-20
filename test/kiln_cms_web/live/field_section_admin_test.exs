defmodule KilnCMSWeb.FieldSectionAdminTest do
  @moduledoc """
  The fields admin's side of #2280 (`/editor/fields`): each type's Sections
  panel lays out the sections its fields are filed under (accordion,
  fieldset or tab, and when an accordion starts open), saving as a select
  changes; the field forms set a field's width.

  Pinned here: the panel writes, updates and removes `FieldSection` rows,
  prunes the rows no field names any more (read fresh, so another admin's new
  section survives), carries a layout along when a section is renamed on its
  last field (decided from a fresh read, so a stale page decides right, #2652),
  drops it with the section's last field, and refuses an event from an admin
  demoted after mounting or one naming a type or section the page does not
  list.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fsadmin-#{System.unique_integer([:positive])}@example.com"

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp field!(admin, name, position, section, opts \\ []) do
    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: name,
        label: String.capitalize(String.replace_prefix(name, "fsa_", "")),
        field_type: :string,
        position: position,
        section: section
      },
      [actor: admin] ++ opts
    )
  end

  defp layouts(opts \\ []),
    do: :page |> CMS.field_sections_for!([authorize?: false] ++ opts) |> Map.new(&{&1.name, &1})

  defp lay_out(lv, index, section) do
    lv
    |> form("#sections-type-page-#{index}-form", %{"section" => section})
    |> render_change()
  end

  describe "the Sections panel" do
    test "lists the sections in use in editor order, as accordions by default", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_notes", 0, "Fsa Dosing")
      field!(admin, "fsa_latin", 1, "Fsa Identity")
      field!(admin, "fsa_dose", 2, "Fsa Dosing")
      field!(admin, "fsa_plain", 3, nil)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert has_element?(lv, ~s(#sections-type-page-0[data-field-section="Fsa Dosing"]))
      assert has_element?(lv, ~s(#sections-type-page-1[data-field-section="Fsa Identity"]))
      refute has_element?(lv, "#sections-type-page-2")

      assert has_element?(
               lv,
               ~s(#sections-type-page-0-display option[value="accordion"][selected])
             )

      refute has_element?(lv, "#sections-type-page-0-initially[disabled]")
    end

    test "is not shown for a type whose fields have no section", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_plain", 0, nil)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert has_element?(lv, "#fields-type-page")
      refute has_element?(lv, "#sections-type-page")
    end

    test "sets a section's display, saved as the select changes", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")
      field!(admin, "fsa_dose", 1, "Fsa Dosing")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "tab"})
      lay_out(lv, 1, %{"display" => "fieldset"})

      assert %{
               "Fsa Identity" => %{display: :tab, initially: :auto},
               "Fsa Dosing" => %{display: :fieldset, initially: :auto}
             } = layouts()

      assert has_element?(lv, ~s(#sections-type-page-0-display option[value="tab"][selected]))
      # "Starts" means nothing for a tab, so it is not offered.
      assert has_element?(lv, "#sections-type-page-0-initially[disabled]")

      lay_out(lv, 0, %{"display" => "fieldset"})
      assert %{"Fsa Identity" => %{display: :fieldset}} = layouts()
    end

    test "sets whether an accordion starts open, kept while it is laid out otherwise",
         %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "accordion", "initially" => "collapsed"})
      assert %{"Fsa Identity" => %{display: :accordion, initially: :collapsed}} = layouts()

      # A tab posts no "Starts" (the select is disabled): the choice stands.
      render_change(lv, "section_layout", %{
        "scope" => "page",
        "name" => "Fsa Identity",
        "section" => %{"display" => "tab"}
      })

      assert %{"Fsa Identity" => %{display: :tab, initially: :collapsed}} = layouts()

      lay_out(lv, 0, %{"display" => "accordion"})
      assert %{"Fsa Identity" => %{display: :accordion, initially: :collapsed}} = layouts()
    end

    test "a section set back to an accordion that opens by itself keeps no row",
         %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "tab"})
      assert %{"Fsa Identity" => _} = layouts()

      lay_out(lv, 0, %{"display" => "accordion"})
      assert layouts() == %{}
      assert has_element?(lv, "#sections-type-page-0")
    end

    test "a save prunes the type's layouts that no field names any more", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Gone", display: :tab},
        actor: admin
      )

      CMS.create_field_section!(%{content_type: :post, name: "Fsa Gone", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "fieldset"})

      assert %{"Fsa Identity" => %{display: :fieldset}} = layouts()
      refute Map.has_key?(layouts(), "Fsa Gone")
      # Another type's rows are that type's to prune.
      assert [%{name: "Fsa Gone"}] = CMS.field_sections_for!(:post, authorize?: false)
    end

    test "a save on a page loaded earlier keeps a section added since", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # Another admin, behind this page's back: a new section, laid out.
      field!(admin, "fsa_dose", 1, "Fsa Dosing")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Dosing", display: :tab},
        actor: admin
      )

      lay_out(lv, 0, %{"display" => "fieldset"})

      assert %{"Fsa Identity" => %{display: :fieldset}, "Fsa Dosing" => %{display: :tab}} =
               layouts()
    end

    test "deleting the last field of a section drops its layout", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")
      dose = field!(admin, "fsa_dose", 1, "Fsa Dosing")
      field!(admin, "amount", 2, "Fsa Dosing")

      for name <- ["Fsa Identity", "Fsa Dosing"],
          do:
            CMS.create_field_section!(%{content_type: :page, name: name, display: :tab},
              actor: admin
            )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "delete", %{"id" => dose.id})
      assert %{"Fsa Identity" => _, "Fsa Dosing" => _} = layouts()

      render_click(lv, "delete", %{"id" => latin.id})
      assert %{"Fsa Dosing" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Fsa Identity")
    end

    test "a rename onto a section with a layout of its own keeps that layout",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # Behind the page's back, the new name gets a layout of its own.
      CMS.create_field_section!(%{content_type: :page, name: "Names", display: :fieldset},
        actor: admin
      )

      render_click(lv, "edit", %{"id" => latin.id})

      html =
        lv
        |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
        |> render_submit()

      refute html =~ "Couldn&#39;t save the section layout."
      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Names"
      assert %{"Names" => %{display: :fieldset}} = layouts()
      refute Map.has_key?(layouts(), "Fsa Identity")
    end

    test "a rename whose layout cannot be carried says so, and saves nothing",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      # A row at the defaults an older release stored with an owner each way:
      # carrying the layout onto it is refused.
      type = CMS.create_type_definition!(%{name: "fsadmin_broken", label: "B"}, actor: admin)

      Ash.Seed.seed!(KilnCMS.CMS.FieldSection, %{
        content_type: :page,
        type_definition_id: type.id,
        name: "Names",
        display: :accordion,
        initially: :auto
      })

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      html =
        lv
        |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
        |> render_submit()

      assert html =~ "Couldn&#39;t save the section layout."
      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Fsa Identity"
      assert %{"Fsa Identity" => %{display: :tab}, "Names" => %{display: :accordion}} = layouts()
    end

    test "a rename on a stale page keeps a layout another admin's field now shares",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # Another admin, behind this page's back: a second field in Identity.
      other = authed_user(:admin)
      field!(other, "fsa_pinyin", 1, "Fsa Identity")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Fsa Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Names")
    end

    test "a rename on a stale page moves a layout its last field now holds alone",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")
      pinyin = field!(admin, "fsa_pinyin", 1, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # Another admin, behind this page's back: pinyin leaves Identity.
      other = authed_user(:admin)
      CMS.update_field_definition!(pinyin, %{section: "Other"}, actor: other)

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Names" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Fsa Identity")
    end

    test "clearing the section of its last field drops its layout (#2881)", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: ""})
      |> render_submit()

      assert CMS.get_field_definition!(latin.id, actor: admin).section == nil
      assert layouts() == %{}
      # No field of the type has a section now, so no panel is left to prune
      # it from: the save itself had to.
      refute has_element?(lv, ~s([data-field-section="Fsa Identity"]))
    end

    test "a rename from a form opened before another admin moved the field keeps no orphan",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
      render_click(lv, "edit", %{"id" => latin.id})

      # Another admin, with the form open: latin moves to Dosing, alone
      # there, and Dosing gets a layout.
      other = authed_user(:admin)
      CMS.update_field_definition!(latin, %{section: "Fsa Dosing"}, actor: other)

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Dosing", display: :fieldset},
        actor: other
      )

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Names"
      # Dosing's layout went with its only field, carried to Names.
      assert %{"Names" => %{display: :fieldset}} = layouts()
      assert Map.keys(layouts()) == ["Names"]
    end

    test "renaming a section on its last field takes its layout along", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")
      field!(admin, "fsa_dose", 1, "Fsa Dosing")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Names" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Fsa Identity")
    end

    test "a section renamed while other fields still carry it keeps its layout",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "fsa_latin", 0, "Fsa Identity")
      field!(admin, "fsa_pinyin", 1, "Fsa Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Fsa Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Names")
    end
  end

  describe "a forged section event" do
    test "naming a section no field of the type carries writes nothing", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "fsa_latin", 0, "Fsa Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      for params <- [
            %{"scope" => "page", "name" => "Nowhere", "section" => %{"display" => "tab"}},
            %{"scope" => "post", "name" => "Fsa Identity", "section" => %{"display" => "tab"}},
            %{
              "scope" => "page",
              "name" => "Fsa Identity",
              "section" => %{"display" => "carousel"}
            },
            %{
              "scope" => "def:#{Ecto.UUID.generate()}",
              "name" => "Fsa Identity",
              "section" => %{"display" => "tab"}
            }
          ] do
        render_change(lv, "section_layout", params)
      end

      assert layouts() == %{}
      assert CMS.field_sections_for!(:post, authorize?: false) == []
    end

    test "naming another site's type and section writes nothing on either site",
         %{conn: conn} do
      admin = authed_user(:admin)
      other = org("fsadmin-other")
      field!(admin, "fsa_latin", 0, "Fsa Identity")
      field!(admin, "secret", 0, "Secret", tenant: other)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      refute has_element?(lv, ~s([data-field-section="Secret"]))

      render_change(lv, "section_layout", %{
        "scope" => "page",
        "name" => "Secret",
        "section" => %{"display" => "tab"}
      })

      assert layouts() == %{}
      assert layouts(tenant: other) == %{}
    end
  end

  describe "authorization on the event" do
    test "an admin demoted after mounting cannot lay out a section", %{conn: conn} do
      platform_admin = authed_user(:admin)
      site = org("fsadmin-site")
      field!(platform_admin, "fsa_latin", 0, "Fsa Identity", tenant: site)

      user = authed_user(:editor)

      membership =
        Ash.Seed.seed!(Accounts.OrgMembership, %{
          user_id: user.id,
          organization_id: site.id,
          role: :admin
        })

      {:ok, lv, _html} = conn |> org_conn(site) |> log_in(user) |> live(~p"/editor/fields")

      Ash.Seed.update!(membership, %{role: :editor})

      html = lay_out(lv, 0, %{"display" => "tab"})

      assert html =~ "You can&#39;t change custom fields."
      assert layouts(tenant: site) == %{}
    end
  end

  describe "authorization on a rename" do
    test "an admin demoted after opening the edit form cannot move a section's last field",
         %{conn: conn} do
      platform_admin = authed_user(:admin)
      site = org("fsadmin-rename")
      latin = field!(platform_admin, "fsa_latin", 0, "Fsa Identity", tenant: site)

      CMS.create_field_section!(%{content_type: :page, name: "Fsa Identity", display: :tab},
        actor: platform_admin,
        tenant: site
      )

      user = authed_user(:editor)

      membership =
        Ash.Seed.seed!(Accounts.OrgMembership, %{
          user_id: user.id,
          organization_id: site.id,
          role: :admin
        })

      {:ok, lv, _html} = conn |> org_conn(site) |> log_in(user) |> live(~p"/editor/fields")
      render_click(lv, "edit", %{"id" => latin.id})

      Ash.Seed.update!(membership, %{role: :editor})

      html =
        lv
        |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
        |> render_submit()

      refute html =~ "Saved."

      assert CMS.get_field_definition!(latin.id, actor: platform_admin, tenant: site).section ==
               "Fsa Identity"

      assert %{"Fsa Identity" => %{display: :tab}} = layouts(tenant: site)
      refute Map.has_key?(layouts(tenant: site), "Names")
    end
  end

  describe "a field's width" do
    test "is set when the field is added", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "fsa_dose",
          label: "Dose",
          field_type: "string",
          width: "half"
        }
      )
      |> render_submit()

      assert %{width: :half} =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.find(&(&1.name == "fsa_dose"))
    end

    test "is changed in the edit form, which shows the stored width", %{conn: conn} do
      admin = authed_user(:admin)
      dose = field!(admin, "fsa_dose", 0, nil)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => dose.id})

      assert has_element?(
               lv,
               ~s(#edit-field-#{dose.id} select[name="field_definition[width]"] option[value="full"][selected])
             )

      lv
      |> form("#edit-field-#{dose.id}", field_definition: %{width: "third"})
      |> render_submit()

      assert %{width: :third} = CMS.get_field_definition!(dose.id, authorize?: false)
    end
  end
end
