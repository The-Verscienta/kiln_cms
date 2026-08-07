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

    # `edit` used a bang fetch with no not-found clause, so clicking Edit on a
    # row another admin had just deleted crashed the LiveView — taking whatever
    # was half-typed into all three create forms down with it (#531).
    test "editing a row that has since been deleted says so instead of crashing",
         %{conn: conn} do
      tag = seed_tag(%{name: "Vanishing"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")

      # Someone else removes it while this page is open.
      CMS.destroy_tag!(tag, authorize?: false)

      html =
        lv
        |> element(~s(button[phx-click="edit"][phx-value-id="#{tag.id}"]))
        |> render_click()

      assert html =~ "no longer available"
      refute html =~ "Vanishing"
    end

    # The delete handler cleared `@edit` unconditionally and record-agnostically,
    # so deleting anything threw away an in-progress inline rename of an
    # unrelated record — and did so even when the delete itself failed (#531).
    test "deleting one record leaves an in-progress edit of another alone", %{conn: conn} do
      keeper = seed_category(%{name: "Keeper"})
      doomed = seed_tag(%{name: "Doomed"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")

      # Start renaming the category...
      lv
      |> element(~s(button[phx-click="edit"][phx-value-id="#{keeper.id}"]))
      |> render_click()

      lv
      |> form("#edit-category-#{keeper.id}", taxonomy: %{name: "Half typed"})
      |> render_change()

      # ...then delete an unrelated tag.
      lv
      |> element(
        ~s(button[phx-click="delete"][phx-value-type="tag"][phx-value-id="#{doomed.id}"])
      )
      |> render_click()

      # The rename is still open, with what was typed into it.
      html = render(lv)
      assert html =~ "edit-category-#{keeper.id}"
      assert html =~ "Half typed"
    end

    # A row someone else already deleted, a row this actor may not delete, and
    # anything else are three different problems. Reporting them all as "you may
    # not have permission" hid the first two — and the obvious way to say more,
    # interpolating Ash's own error rendering, puts a class header and the raw
    # primary key in the flash, in English, whatever the locale (#531).
    test "a delete of a since-deleted row says so, and clears the phantom row",
         %{conn: conn} do
      tag = seed_tag(%{name: "Phantom"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/taxonomy")
      CMS.destroy_tag!(tag, authorize?: false)

      html =
        lv
        |> element(~s(button[phx-click="delete"][phx-value-id="#{tag.id}"]))
        |> render_click()

      assert html =~ "no longer available"
      # Not Ash's internals, and not the record's id.
      refute html =~ "Input Invalid"
      refute html =~ tag.id

      # The row is gone from the page, so the only affordance isn't to click
      # Delete again and get the same message.
      refute html =~ "Phantom"
    end

    # Taxonomy is world-readable, so an editor's fetch succeeds and only the
    # admin-only destroy policy refuses — a genuinely different message.
    test "a delete an editor isn't allowed says so, and keeps the row", %{conn: conn} do
      tag = seed_tag(%{name: "Protected"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      # The editor's page renders no delete button, so push the event directly —
      # the server must refuse on the policy, not on the missing control.
      html = render_click(lv, "delete", %{"type" => "tag", "id" => tag.id})

      assert html =~ "permission"
      assert html =~ "Protected"
      assert Enum.any?(CMS.list_tags!(authorize?: false), &(&1.id == tag.id))
    end

    # Every kind's flash comes out of one `labels/1` table now, so a copy/paste
    # swap between rows would go unnoticed.
    test "each kind's create flash names that kind", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      assert lv
             |> form("#new-category-form", category: %{name: "Flash Cat"})
             |> render_submit() =~ "Category added."

      assert lv
             |> form("#new-tag_group-form", tag_group: %{name: "Flash Group"})
             |> render_submit() =~ "Tag group added."

      assert lv
             |> form("#new-tag-form", tag: %{name: "Flash Tag"})
             |> render_submit() =~ "Tag added."
    end

    # `kind_params/1` finds the kind by which form key the payload carries. A
    # payload naming none used to be a `MatchError` that took the LiveView down
    # — discarding all three half-typed create forms, the very failure the edit
    # handler was fixed to avoid.
    test "a validate payload naming no known kind is ignored, not fatal", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/taxonomy")

      lv |> form("#new-category-form", category: %{name: "Still here"}) |> render_change()

      render_change(lv, "validate", %{"not_a_kind" => %{"name" => "x"}})
      render_change(lv, "create", %{"not_a_kind" => %{"name" => "x"}})

      assert render(lv) =~ "Still here"
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
