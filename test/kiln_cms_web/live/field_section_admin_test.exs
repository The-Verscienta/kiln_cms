defmodule KilnCMSWeb.FieldSectionAdminTest do
  @moduledoc """
  The fields admin's side of #2280 (`/editor/fields`): each type's Sections
  panel lays out the sections its fields are filed under (accordion,
  fieldset or tab, and when an accordion starts open), saving as a select
  changes; the field forms set a field's width.

  Pinned here: the panel writes, updates and removes `FieldSection` rows,
  prunes the rows no field names any more (read fresh, so another admin's new
  section survives), carries a layout along when a section is renamed on its
  last field, drops it with the section's last field, and refuses an event from an admin
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
        label: String.capitalize(name),
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
      field!(admin, "notes", 0, "Dosing")
      field!(admin, "latin", 1, "Identity")
      field!(admin, "dose", 2, "Dosing")
      field!(admin, "plain", 3, nil)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert has_element?(lv, ~s(#sections-type-page-0[data-field-section="Dosing"]))
      assert has_element?(lv, ~s(#sections-type-page-1[data-field-section="Identity"]))
      refute has_element?(lv, "#sections-type-page-2")

      assert has_element?(
               lv,
               ~s(#sections-type-page-0-display option[value="accordion"][selected])
             )

      refute has_element?(lv, "#sections-type-page-0-initially[disabled]")
    end

    test "is not shown for a type whose fields have no section", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "plain", 0, nil)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      assert has_element?(lv, "#fields-type-page")
      refute has_element?(lv, "#sections-type-page")
    end

    test "sets a section's display, saved as the select changes", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")
      field!(admin, "dose", 1, "Dosing")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "tab"})
      lay_out(lv, 1, %{"display" => "fieldset"})

      assert %{
               "Identity" => %{display: :tab, initially: :auto},
               "Dosing" => %{display: :fieldset, initially: :auto}
             } = layouts()

      assert has_element?(lv, ~s(#sections-type-page-0-display option[value="tab"][selected]))
      # "Starts" means nothing for a tab, so it is not offered.
      assert has_element?(lv, "#sections-type-page-0-initially[disabled]")

      lay_out(lv, 0, %{"display" => "fieldset"})
      assert %{"Identity" => %{display: :fieldset}} = layouts()
    end

    test "sets whether an accordion starts open, kept while it is laid out otherwise",
         %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "accordion", "initially" => "collapsed"})
      assert %{"Identity" => %{display: :accordion, initially: :collapsed}} = layouts()

      # A tab posts no "Starts" (the select is disabled): the choice stands.
      render_change(lv, "section_layout", %{
        "scope" => "page",
        "name" => "Identity",
        "section" => %{"display" => "tab"}
      })

      assert %{"Identity" => %{display: :tab, initially: :collapsed}} = layouts()

      lay_out(lv, 0, %{"display" => "accordion"})
      assert %{"Identity" => %{display: :accordion, initially: :collapsed}} = layouts()
    end

    test "a section set back to an accordion that opens by itself keeps no row",
         %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "tab"})
      assert %{"Identity" => _} = layouts()

      lay_out(lv, 0, %{"display" => "accordion"})
      assert layouts() == %{}
      assert has_element?(lv, "#sections-type-page-0")
    end

    test "a save prunes the type's layouts that no field names any more", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")
      CMS.create_field_section!(%{content_type: :page, name: "Gone", display: :tab}, actor: admin)

      CMS.create_field_section!(%{content_type: :post, name: "Gone", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lay_out(lv, 0, %{"display" => "fieldset"})

      assert %{"Identity" => %{display: :fieldset}} = layouts()
      refute Map.has_key?(layouts(), "Gone")
      # Another type's rows are that type's to prune.
      assert [%{name: "Gone"}] = CMS.field_sections_for!(:post, authorize?: false)
    end

    test "a save on a page loaded earlier keeps a section added since", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      # Another admin, behind this page's back: a new section, laid out.
      field!(admin, "dose", 1, "Dosing")

      CMS.create_field_section!(%{content_type: :page, name: "Dosing", display: :tab},
        actor: admin
      )

      lay_out(lv, 0, %{"display" => "fieldset"})

      assert %{"Identity" => %{display: :fieldset}, "Dosing" => %{display: :tab}} = layouts()
    end

    test "deleting the last field of a section drops its layout", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "latin", 0, "Identity")
      dose = field!(admin, "dose", 1, "Dosing")
      field!(admin, "amount", 2, "Dosing")

      for name <- ["Identity", "Dosing"],
          do:
            CMS.create_field_section!(%{content_type: :page, name: name, display: :tab},
              actor: admin
            )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "delete", %{"id" => dose.id})
      assert %{"Identity" => _, "Dosing" => _} = layouts()

      render_click(lv, "delete", %{"id" => latin.id})
      assert %{"Dosing" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Identity")
    end

    test "a rename whose layout cannot be carried says so", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "latin", 0, "Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Identity", display: :tab},
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

      assert html =~ "Couldn&#39;t save the section layout."
      assert %{"Names" => %{display: :fieldset}, "Identity" => %{display: :tab}} = layouts()
    end

    test "renaming a section on its last field takes its layout along", %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "latin", 0, "Identity")
      field!(admin, "dose", 1, "Dosing")

      CMS.create_field_section!(%{content_type: :page, name: "Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Names" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Identity")
    end

    test "a section renamed while other fields still carry it keeps its layout",
         %{conn: conn} do
      admin = authed_user(:admin)
      latin = field!(admin, "latin", 0, "Identity")
      field!(admin, "pinyin", 1, "Identity")

      CMS.create_field_section!(%{content_type: :page, name: "Identity", display: :tab},
        actor: admin
      )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      render_click(lv, "edit", %{"id" => latin.id})

      lv
      |> form("#edit-field-#{latin.id}", field_definition: %{section: "Names"})
      |> render_submit()

      assert %{"Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Names")
    end
  end

  describe "a forged section event" do
    test "naming a section no field of the type carries writes nothing", %{conn: conn} do
      admin = authed_user(:admin)
      field!(admin, "latin", 0, "Identity")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      for params <- [
            %{"scope" => "page", "name" => "Nowhere", "section" => %{"display" => "tab"}},
            %{"scope" => "post", "name" => "Identity", "section" => %{"display" => "tab"}},
            %{"scope" => "page", "name" => "Identity", "section" => %{"display" => "carousel"}},
            %{
              "scope" => "def:#{Ecto.UUID.generate()}",
              "name" => "Identity",
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
      field!(admin, "latin", 0, "Identity")
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
      field!(platform_admin, "latin", 0, "Identity", tenant: site)

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

  describe "a field's width" do
    test "is set when the field is added", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form",
        field_definition: %{
          scopes: ["page"],
          name: "dose",
          label: "Dose",
          field_type: "string",
          width: "half"
        }
      )
      |> render_submit()

      assert %{width: :half} =
               :page
               |> CMS.field_definitions_for!(authorize?: false)
               |> Enum.find(&(&1.name == "dose"))
    end

    test "is changed in the edit form, which shows the stored width", %{conn: conn} do
      admin = authed_user(:admin)
      dose = field!(admin, "dose", 0, nil)

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
