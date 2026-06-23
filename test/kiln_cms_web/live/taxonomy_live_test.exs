defmodule KilnCMSWeb.TaxonomyLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.Tag

  @password "password123456"

  defp authed_user(role) do
    email = "tax-#{System.unique_integer([:positive])}@example.com"

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

  defp seed_category(attrs \\ %{}) do
    Ash.Seed.seed!(
      Category,
      Map.merge(%{name: "Cat", slug: "cat-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp seed_tag(attrs) do
    Ash.Seed.seed!(
      Tag,
      Map.merge(%{name: "Tag", slug: "tag-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  describe "access control" do
    test "viewers are redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(authed_user(:viewer)) |> live(~p"/editor/taxonomy")
    end

    test "editors can reach the page", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")
      assert html =~ "Taxonomy"
      assert html =~ "Categories"
      assert html =~ "Tags"
    end
  end

  describe "creating taxonomy" do
    test "an editor adds a category, slug auto-generated from the name", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      lv |> form("#new-category-form", category: %{name: "Breaking News"}) |> render_submit()

      assert [cat] =
               CMS.list_categories!(authorize?: false)
               |> Enum.filter(&(&1.name == "Breaking News"))

      assert cat.slug == "breaking-news"
    end

    test "an editor adds a tag with an explicit slug", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      lv |> form("#new-tag-form", tag: %{name: "Elixir", slug: "ex-lang"}) |> render_submit()

      assert Enum.any?(CMS.list_tags!(authorize?: false), &(&1.slug == "ex-lang"))
    end

    test "a duplicate slug surfaces a validation error instead of crashing", %{conn: conn} do
      seed_category(%{name: "Existing", slug: "dupe-slug"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      html =
        lv
        |> form("#new-category-form", category: %{name: "Other", slug: "dupe-slug"})
        |> render_submit()

      # Still on the page, only the original category persisted.
      assert html =~ "Taxonomy"

      assert length(
               Enum.filter(CMS.list_categories!(authorize?: false), &(&1.slug == "dupe-slug"))
             ) == 1
    end
  end

  describe "editing taxonomy" do
    test "an editor renames a category inline", %{conn: conn} do
      cat = seed_category(%{name: "Old name"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{cat.id}"]))
      |> render_click()

      lv |> form("#edit-category-#{cat.id}", taxonomy: %{name: "New name"}) |> render_submit()

      assert CMS.get_category!(cat.id, authorize?: false).name == "New name"
    end
  end

  describe "deleting taxonomy" do
    test "the delete control is admin-only", %{conn: conn} do
      seed_category()

      {:ok, _lv, editor_html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      refute editor_html =~ ~s(phx-click="delete")

      {:ok, _lv, admin_html} =
        build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")

      assert admin_html =~ ~s(phx-click="delete")
    end

    test "an admin deletes a tag", %{conn: conn} do
      tag = seed_tag(%{name: "Disposable"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")

      lv
      |> element(~s(button[phx-click="delete"][phx-value-type="tag"][phx-value-id="#{tag.id}"]))
      |> render_click()

      refute Enum.any?(CMS.list_tags!(authorize?: false), &(&1.id == tag.id))
    end
  end

  describe "usage counts" do
    test "shows how many items use a category", %{conn: conn} do
      editor = authed_user(:editor)
      cat = seed_category(%{name: "Counted"})

      CMS.create_post!(
        %{title: "P", slug: "u-#{System.unique_integer([:positive])}", category_id: cat.id},
        actor: editor
      )

      {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/taxonomy")

      # "1 post" appears in the row for the counted category.
      assert html =~ "1 post"
    end
  end
end
