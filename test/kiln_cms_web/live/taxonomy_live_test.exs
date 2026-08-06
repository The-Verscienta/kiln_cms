defmodule KilnCMSWeb.TaxonomyLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.Tag
  alias KilnCMS.CMS.TagGroup

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

  defp seed_tag_group(attrs) do
    Ash.Seed.seed!(
      TagGroup,
      Map.merge(%{name: "Group", slug: "group-#{System.unique_integer([:positive])}"}, attrs)
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

  describe "tag groups" do
    test "an editor adds a group scoped to one content type", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      lv
      |> form("#new-tag_group-form",
        tag_group: %{name: "Post themes", content_types: ["post"]}
      )
      |> render_submit()

      assert [group] =
               CMS.list_tag_groups!(authorize?: false)
               |> Enum.filter(&(&1.name == "Post themes"))

      assert group.slug == "post-themes"
      assert group.content_types == ["post"]
    end

    test "a group with no content types checked applies everywhere", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      # The hidden sentinel input is what a browser submits when every checkbox
      # in the group is unchecked; it must normalize to [] rather than [""].
      lv
      |> form("#new-tag_group-form", tag_group: %{name: "Topics", content_types: [""]})
      |> render_submit()

      assert [group] =
               CMS.list_tag_groups!(authorize?: false)
               |> Enum.filter(&(&1.name == "Topics"))

      assert group.content_types == []
    end

    test "tags are listed under their group's heading", %{conn: conn} do
      group = seed_tag_group(%{name: "Cuisines"})
      seed_tag(%{name: "Thai", tag_group_id: group.id})

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      assert html =~ "Cuisines"
      assert html =~ "Thai"
    end

    test "the delete confirmation says tags survive the group", %{conn: _conn} do
      group = seed_tag_group(%{name: "Doomed"})
      seed_tag(%{name: "Kept", tag_group_id: group.id})

      {:ok, _lv, html} = build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")

      assert html =~ "become ungrouped"
    end

    test "a scope entry naming no live type renders as (unknown) (#526)", %{conn: conn} do
      # Seeded to bypass the KnownContentTypes validation — models a pre-existing
      # bad row or a TypeDefinition renamed out from under the group.
      seed_tag_group(%{name: "Stale scope", content_types: ["ghosttype", "post"]})

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      # The unresolvable entry is flagged; the real one shows its label, not "(unknown)".
      assert html =~ "ghosttype (unknown)"
      refute html =~ "post (unknown)"
    end

    # A tag pointing at a group the page didn't load (a cross-tenant `tag_group_id`
    # — the FK carries no org component — or one raced in after load) must fall
    # into "Ungrouped", not vanish: dropping it hid its Edit/Delete controls and
    # skewed the "Tags (N)" count (#525). This can't be reproduced through the DB
    # here — the fail-open suite loads every group `global?` and the `nilify` FK
    # forbids a dangling id — so exercise the pure bucketing directly.
    test "a tag in an unloaded group buckets as ungrouped rather than disappearing" do
      # Two loaded groups so we can also assert picker order is preserved and the
      # Ungrouped bucket lands last.
      first = %TagGroup{id: Ecto.UUID.generate(), name: "First"}
      second = %TagGroup{id: Ecto.UUID.generate(), name: "Second"}
      absent_id = Ecto.UUID.generate()

      in_first = %Tag{id: Ecto.UUID.generate(), name: "Filed", tag_group_id: first.id}
      orphan = %Tag{id: Ecto.UUID.generate(), name: "Orphan", tag_group_id: absent_id}
      loose = %Tag{id: Ecto.UUID.generate(), name: "Loose", tag_group_id: nil}

      buckets =
        KilnCMSWeb.TaxonomyLive.group_tags([in_first, orphan, loose], [first, second])

      # Every tag survives — none is silently dropped.
      bucketed = for {_id, _name, tags} <- buckets, t <- tags, do: t.name
      assert Enum.sort(bucketed) == ["Filed", "Loose", "Orphan"]

      # Loaded groups keep picker order; the empty one still shows; Ungrouped last.
      assert [
               {first_id, "First", [in_first]},
               {second_id, "Second", []},
               {nil, ungrouped_label, ungrouped}
             ] =
               buckets

      assert first_id == first.id
      assert second_id == second.id
      assert ungrouped_label =~ "Ungrouped"
      # Both the null-group tag and the unknown-group tag land under "Ungrouped".
      assert Enum.map(ungrouped, & &1.name) |> Enum.sort() == ["Loose", "Orphan"]
    end

    test "no ungrouped bucket appears when every tag is filed under a loaded group" do
      loaded = %TagGroup{id: Ecto.UUID.generate(), name: "Loaded"}
      filed = %Tag{id: Ecto.UUID.generate(), name: "Filed", tag_group_id: loaded.id}

      buckets = KilnCMSWeb.TaxonomyLive.group_tags([filed], [loaded])

      assert buckets == [{loaded.id, "Loaded", [filed]}]
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
