defmodule KilnCMSWeb.ContentEditorInlineTermsTest do
  @moduledoc """
  Adding a tag or a category without leaving the content editor (#1805).

  The editor only ever *selects* the new term — it is ticked (or picked in the
  Category select) like an existing one, so these tests save through the form
  and read the entry back rather than trusting the rendered state.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Tag
  alias KilnCMSWeb.ContentEditor.InlineTerms
  alias KilnCMSWeb.ContentEditor.InspectorComponents

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role) do
    email = "terms-#{uniq()}@example.com"

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

  defp draft_page do
    Ash.Seed.seed!(Page, %{title: "A page", slug: "terms-#{uniq()}", state: :draft})
  end

  defp open_editor(conn, page, role \\ :editor) do
    {:ok, lv, html} =
      conn |> log_in(authed_user(role)) |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp saved_page(page), do: CMS.get_page!(page.id, authorize?: false, load: [:tags, :category])

  # Tags whose name matches `name` case-insensitively — distinct names per test
  # keep this independent of whatever else the async suite has seeded.
  defp tags_named(name) do
    wanted = String.downcase(name)
    CMS.list_tags!(authorize?: false) |> Enum.filter(&(String.downcase(&1.name) == wanted))
  end

  defp categories_named(name) do
    wanted = String.downcase(name)

    CMS.list_categories!(authorize?: false)
    |> Enum.filter(&(String.downcase(&1.name) == wanted))
  end

  defp checked_tag_ids(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("#tag-picker input[type=checkbox][checked]")
    |> Enum.flat_map(&Floki.attribute(&1, "value"))
  end

  defp selected_category(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("select[name='form[category_id]'] option[selected]")
    |> Enum.flat_map(&Floki.attribute(&1, "value"))
  end

  describe "tags" do
    test "an editor creates a tag from the filter box, and Save attaches it", %{conn: conn} do
      page = draft_page()
      name = "Fresh tag #{uniq()}"
      {lv, _html} = open_editor(conn, page)

      html = render_hook(lv, "filter_tags", %{"q" => name})
      assert html =~ "Create tag “#{name}”"

      html = lv |> element("#tag-picker-create") |> render_click()

      assert [tag] = tags_named(name)
      assert tag.slug == KilnCMS.Slug.slugify(name)
      # Ticked in the picker (and the filter cleared, so the button is gone)…
      assert to_string(tag.id) in checked_tag_ids(html)
      refute html =~ "Create tag"
      # …but not attached until the entry is saved, like any other tick.
      assert saved_page(page).tags == []

      lv |> form("#page-editor") |> render_submit()
      assert [%{id: id}] = saved_page(page).tags
      assert id == tag.id
    end

    test "Enter in the filter box creates the tag (the hook's push)", %{conn: conn} do
      page = draft_page()
      name = "Entered #{uniq()}"
      {lv, _html} = open_editor(conn, page)

      html = render_hook(lv, "create_tag", %{"name" => "  #{name}  "})

      assert [tag] = tags_named(name)
      assert tag.name == name
      assert to_string(tag.id) in checked_tag_ids(html)
    end

    test "a name that already exists ticks that tag instead of adding a second", %{conn: conn} do
      page = draft_page()
      name = "Existing#{uniq()}"
      existing = Ash.Seed.seed!(Tag, %{name: name, slug: "existing-#{uniq()}"})
      {lv, _html} = open_editor(conn, page)

      # An exact (case-insensitive) match is on screen: nothing to offer.
      refute render_hook(lv, "filter_tags", %{"q" => String.downcase(name)}) =~ "Create tag"

      html = render_hook(lv, "create_tag", %{"name" => String.upcase(name)})
      assert [%{id: id}] = tags_named(name)
      assert id == existing.id
      assert to_string(existing.id) in checked_tag_ids(html)
    end

    test "a different name whose slug is taken gets a suffixed slug", %{conn: conn} do
      page = draft_page()
      base = "clash#{uniq()}"
      Ash.Seed.seed!(Tag, %{name: base, slug: base})
      {lv, _html} = open_editor(conn, page)

      render_hook(lv, "create_tag", %{"name" => base <> "!"})

      assert [tag] = tags_named(base <> "!")
      assert String.starts_with?(tag.slug, base <> "-")
    end

    test "a blank name does nothing", %{conn: conn} do
      page = draft_page()
      {lv, _html} = open_editor(conn, page)
      before = length(CMS.list_tags!(authorize?: false))

      render_hook(lv, "create_tag", %{"name" => "   "})

      assert length(CMS.list_tags!(authorize?: false)) == before
      refute render(lv) =~ "Couldn&#39;t add"
    end
  end

  describe "categories" do
    test "an editor adds a category inline, it is selected, and Save keeps it", %{conn: conn} do
      page = draft_page()
      name = "Recipes #{uniq()}"
      {lv, html} = open_editor(conn, page)

      assert html =~ "New category"
      refute has_element?(lv, "#category-new-name")

      lv |> element("#category-new") |> render_click()
      assert has_element?(lv, "#category-new-name")

      lv |> element("#category-new-name") |> render_change(%{"new_category_name" => name})
      html = lv |> element("#category-new-add") |> render_click()

      assert [category] = categories_named(name)
      assert selected_category(html) == [to_string(category.id)]
      refute has_element?(lv, "#category-new-name")
      assert saved_page(page).category_id == nil

      lv |> form("#page-editor") |> render_submit()
      assert saved_page(page).category_id == category.id
    end

    test "Enter in the name field adds it (the hook's push)", %{conn: conn} do
      page = draft_page()
      name = "Entered cat #{uniq()}"
      {lv, _html} = open_editor(conn, page)

      lv |> element("#category-new") |> render_click()
      html = render_hook(lv, "create_category", %{"name" => name})

      assert [category] = categories_named(name)
      assert selected_category(html) == [to_string(category.id)]
    end

    test "an existing name selects that category", %{conn: conn} do
      page = draft_page()
      name = "News#{uniq()}"
      existing = Ash.Seed.seed!(Category, %{name: name, slug: "news-#{uniq()}"})
      {lv, _html} = open_editor(conn, page)

      lv |> element("#category-new") |> render_click()
      html = render_hook(lv, "create_category", %{"name" => String.downcase(name)})

      assert [%{id: id}] = categories_named(name)
      assert id == existing.id
      assert selected_category(html) == [to_string(existing.id)]
    end

    test "a refused write shows its message and keeps the field open", %{conn: conn} do
      page = draft_page()
      {lv, _html} = open_editor(conn, page)

      lv |> element("#category-new") |> render_click()
      # Past the name's length limit: a validation error the editor can read.
      too_long = String.duplicate("x", KilnCMS.Limits.line() + 1)
      render_hook(lv, "create_category", %{"name" => too_long})

      assert has_element?(lv, "#category-new-error")
      assert has_element?(lv, "#category-new-name")
    end

    test "the create event is ignored while the field is closed", %{conn: conn} do
      page = draft_page()
      name = "Closed #{uniq()}"
      {lv, _html} = open_editor(conn, page)

      render_hook(lv, "create_category", %{"name" => name})
      assert categories_named(name) == []
    end
  end

  # Viewers never reach the editor (`:live_editor_required`), so the gate is
  # proven where it lives: the `can_create?/3` answer the editor mounts with,
  # the components that answer hides, and the write itself.
  describe "authorization" do
    setup do
      %{org: KilnCMS.Accounts.default_org()}
    end

    test "only editors and admins may create terms", %{org: org} do
      for kind <- [:tag, :category] do
        assert InlineTerms.can_create?(kind, authed_user(:editor), org)
        assert InlineTerms.can_create?(kind, authed_user(:admin), org)
        refute InlineTerms.can_create?(kind, authed_user(:viewer), org)
        refute InlineTerms.can_create?(kind, nil, org)
      end
    end

    test "a viewer's write is refused with a readable message", %{org: org} do
      viewer = authed_user(:viewer)
      name = "Viewer #{uniq()}"

      assert {:error, message} = InlineTerms.find_or_create(:tag, name, viewer, org)
      assert message =~ "permission"
      assert tags_named(name) == []
    end

    test "the tag picker offers create only when allowed" do
      assigns = [
        form: Phoenix.Component.to_form(%{}, as: :form),
        tag_index: %{sections: [], pickable?: false, rendered: MapSet.new()},
        record: %{tags: []},
        open_sections: MapSet.new(),
        tag_query: "Brand new"
      ]

      allowed =
        render_component(&InspectorComponents.tag_picker/1, [can_create?: true] ++ assigns)

      assert allowed =~ "Create tag “Brand new”"

      refused =
        render_component(&InspectorComponents.tag_picker/1, [can_create?: false] ++ assigns)

      refute refused =~ "Create tag"
    end

    test "the Category field offers New category only when allowed" do
      assigns = [form: Phoenix.Component.to_form(%{}, as: :form), categories: []]

      assert render_component(
               &InspectorComponents.category_field/1,
               [can_create?: true] ++ assigns
             ) =~
               "New category"

      refute render_component(
               &InspectorComponents.category_field/1,
               [can_create?: false, draft: ""] ++ assigns
             ) =~ "category-new"
    end
  end
end
