defmodule KilnCMSWeb.EditorLiveViewsTest do
  @moduledoc """
  The content list's facets, sort and saved views (#1593): each facet narrows
  the list from the URL, the URL round-trips through the form and the chips,
  paging stays exact under every sort, and saved views can be saved, renamed
  and deleted by the people the policy allows.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.CMS.Tag

  @password "password123456"

  defp authed_user(role) do
    email = "views-#{System.unique_integer([:positive])}@example.com"

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

  defp uniq, do: System.unique_integer([:positive])

  # Every title carries `prefix` so a test can scope the list with `q=` and
  # ignore whatever else the shared sandbox holds.
  defp a_post(prefix, attrs \\ %{}) do
    Ash.Seed.seed!(
      Post,
      Map.merge(%{title: "#{prefix} post #{uniq()}", slug: "vp-#{uniq()}", state: :draft}, attrs)
    )
  end

  defp a_page(prefix, attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "#{prefix} page #{uniq()}", slug: "vg-#{uniq()}", state: :draft}, attrs)
    )
  end

  defp prefix, do: "vw#{uniq()}"

  defp visible_ids(html) do
    ~r/id="(?:post|page)-([0-9a-f-]{36})"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
  end

  describe "facets" do
    test "author=me lists only the actor's content", %{conn: conn} do
      editor = authed_user(:editor)
      other = authed_user(:editor)
      p = prefix()
      mine = a_post(p, %{author_id: editor.id})
      theirs = a_post(p, %{author_id: other.id})

      {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor?q=#{p}&author=me")

      assert html =~ mine.title
      refute html =~ theirs.title
      assert html =~ "Author: me"
      assert html =~ "1 item"
    end

    test "a named author, a category and a tag each narrow the list", %{conn: conn} do
      editor = authed_user(:editor)
      other = authed_user(:editor)
      p = prefix()
      cat = Ash.Seed.seed!(Category, %{name: "Field notes", slug: "c-#{uniq()}"})
      tag = Ash.Seed.seed!(Tag, %{name: "elixir", slug: "t-#{uniq()}"})

      by_other = a_post(p, %{author_id: other.id})
      in_cat = a_post(p, %{category_id: cat.id})
      tagged = a_post(p)

      Ash.Seed.seed!(KilnCMS.CMS.Tagging, %{
        org_id: tagged.org_id,
        subject_id: tagged.id,
        tag_id: tag.id
      })

      conn = log_in(conn, editor)

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&author=#{other.id}")
      assert visible_ids(html) == [by_other.id]

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&category=#{cat.id}")
      assert visible_ids(html) == [in_cat.id]
      assert html =~ "Category: Field notes"

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&tag=#{tag.id}")
      assert visible_ids(html) == [tagged.id]
      assert html =~ "Tag: elixir"
    end

    test "locale, update-date range, schedule and review health narrow the list",
         %{conn: conn} do
      editor = authed_user(:editor)
      p = prefix()
      now = DateTime.utc_now()

      french = a_post(p, %{locale: "fr"})
      old = a_post(p, %{updated_at: ~U[2024-03-10 12:00:00.000000Z]})
      scheduled = a_post(p, %{scheduled_at: DateTime.add(now, 3, :day)})

      due =
        a_post(p, %{
          state: :published,
          published_at: DateTime.add(now, -40, :day),
          review_after_days: 30
        })

      conn = log_in(conn, editor)

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&locale=fr")
      assert visible_ids(html) == [french.id]

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&from=2024-03-01&to=2024-03-10")
      assert visible_ids(html) == [old.id]

      # `to` is inclusive of its whole day; the day before excludes the row.
      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&from=2024-03-01&to=2024-03-09")
      assert visible_ids(html) == []

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&scheduled=1")
      assert visible_ids(html) == [scheduled.id]

      {:ok, _lv, html} = live(conn, ~p"/editor?q=#{p}&health=due")
      assert visible_ids(html) == [due.id]
    end

    test "values that cannot be valid read as absent", %{conn: conn} do
      editor = authed_user(:editor)
      p = prefix()
      row = a_post(p)

      {:ok, _lv, html} =
        conn
        |> log_in(editor)
        |> live(
          ~p"/editor?q=#{p}&author=nobody&category=x&tag[]=1&locale=xx&from=soon&health=bad&sort=random&scheduled=yes"
        )

      assert visible_ids(html) == [row.id]
      refute html =~ "Remove filter: Author"
    end
  end

  describe "the URL round trip" do
    test "the facet panel patches the URL, and a remount restores it", %{conn: conn} do
      editor = authed_user(:editor)
      p = prefix()
      mine = a_post(p, %{author_id: editor.id})
      a_post(p)
      conn = log_in(conn, editor)

      {:ok, lv, _html} = live(conn, ~p"/editor?q=#{p}")

      lv |> element("#toggle-filters") |> render_click()
      assert has_element?(lv, "#toggle-filters[aria-expanded=true]")

      lv |> form("#content-filter", %{author: "me", sort: "title"}) |> render_change()
      path = assert_patch(lv)
      assert path =~ "author=me"
      assert path =~ "sort=title"
      assert path =~ "q=#{p}"

      {:ok, _lv, html} = live(conn, path)
      assert visible_ids(html) == [mine.id]
      assert html =~ ~s(value="title" selected)
    end

    test "a chip removes its facet and keeps the others", %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor?status=draft&author=me")

      lv |> element("button[aria-label='Remove filter: Author: me']") |> render_click()
      assert assert_patch(lv) == ~p"/editor?status=draft"
    end

    test "clearing filters returns to the bare list", %{conn: conn} do
      editor = authed_user(:editor)
      a_post("clr")
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor?status=draft&sort=title")

      lv |> element("button", "Clear filters") |> render_click()
      assert assert_patch(lv) == ~p"/editor"
    end
  end

  describe "paging" do
    # 60 rows across two types: Load more must show each exactly once, in the
    # sort's order, whatever the sort.
    for sort <- ~w(updated published title) do
      test "Load more is exact across types when sorted by #{sort}", %{conn: conn} do
        editor = authed_user(:editor)
        p = prefix()
        base = ~U[2025-01-01 00:00:00.000000Z]

        rows =
          for i <- 1..60 do
            attrs = %{
              title: "#{p} #{String.pad_leading(to_string(rem(i * 37, 61)), 3, "0")}",
              updated_at: DateTime.add(base, i, :minute),
              # Every third row was never published — the nulls sort last.
              published_at: if(rem(i, 3) == 0, do: nil, else: DateTime.add(base, -i, :hour))
            }

            if rem(i, 2) == 0, do: a_post(p, attrs), else: a_page(p, attrs)
          end

        {:ok, lv, html} =
          conn |> log_in(editor) |> live(~p"/editor?q=#{p}&sort=#{unquote(sort)}")

        assert length(visible_ids(html)) == 50
        assert html =~ "60 items"

        html = lv |> element("button", "Load more") |> render_click()
        ids = visible_ids(html)

        assert length(ids) == 60
        assert Enum.uniq(ids) == ids
        refute has_element?(lv, "button", "Load more")

        expected =
          case unquote(sort) do
            "updated" ->
              Enum.sort_by(rows, & &1.updated_at, {:desc, DateTime})

            "title" ->
              Enum.sort_by(rows, & &1.title)

            "published" ->
              {dated, undated} = Enum.split_with(rows, & &1.published_at)

              Enum.sort_by(dated, & &1.published_at, {:desc, DateTime}) ++
                Enum.sort_by(undated, & &1.id, :desc)
          end

        assert ids == Enum.map(expected, & &1.id)
      end
    end
  end

  describe "built-in views" do
    test "are listed, and the one on screen is marked current", %{conn: conn} do
      editor = authed_user(:editor)
      a_post("dv")
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor?status=draft&author=me")

      for name <- ["All content", "My drafts", "Needs review", "Scheduled", "Review due"] do
        assert has_element?(lv, "#content-views a", name)
      end

      assert has_element?(lv, "#view-my-drafts[aria-current=page]")
      refute has_element?(lv, "#view-all[aria-current=page]")
      # A built-in view is already saved: no Save button for it.
      refute has_element?(lv, "#save-view")

      lv |> element("#view-needs-review") |> render_click()
      assert assert_patch(lv) == ~p"/editor?status=in_review"
      assert has_element?(lv, "#view-needs-review[aria-current=page]")
    end
  end

  describe "saved views" do
    test "an editor saves, renames and deletes a private view", %{conn: conn} do
      editor = authed_user(:editor)
      a_post("sv")
      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor?status=published&sort=title")

      # Editors are not offered the share box.
      lv |> element("#save-view") |> render_click()
      refute has_element?(lv, "#save-view-form input[name=shared]")

      lv |> form("#save-view-form", %{name: "Live, A to Z"}) |> render_submit()
      assert render(lv) =~ "Saved the view “Live, A to Z”."

      [view] = CMS.list_saved_views!(actor: editor, tenant: Accounts.default_org_id())
      assert view.params == %{"status" => "published", "sort" => "title"}
      assert has_element?(lv, "#view-#{view.id}[aria-current=page]", "Live, A to Z")
      refute has_element?(lv, "#save-view")

      lv |> element("button", "Rename") |> render_click()
      lv |> form("#rename-view-form", %{name: "Published"}) |> render_submit()
      assert has_element?(lv, "#view-#{view.id}", "Published")

      lv |> element("button", "Delete view") |> render_click()
      assert has_element?(lv, "#delete-view-confirm")
      lv |> element("#delete-view-confirm button", "Delete view") |> render_click()

      refute has_element?(lv, "#view-#{view.id}")
      assert CMS.list_saved_views!(actor: editor, tenant: Accounts.default_org_id()) == []
    end

    test "an admin shares a view; other editors see it but cannot change it", %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      a_post("sh")

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor?status=draft&sort=title")
      lv |> element("#save-view") |> render_click()
      lv |> form("#save-view-form", %{name: "Team drafts", shared: "true"}) |> render_submit()

      [view] = CMS.list_saved_views!(actor: admin, tenant: Accounts.default_org_id())
      assert view.shared

      {:ok, lv, _html} =
        build_conn() |> log_in(editor) |> live(~p"/editor?status=draft&sort=title")

      assert has_element?(lv, "#view-#{view.id}[aria-current=page]", "Team drafts")
      refute has_element?(lv, "button", "Rename")
      refute has_element?(lv, "button", "Delete view")

      # A crafted event is refused by the policy, not just hidden.
      render_hook(lv, "confirm_delete_view", %{"id" => view.id})

      assert [_still_there] =
               CMS.list_saved_views!(actor: admin, tenant: Accounts.default_org_id())
    end

    test "another editor's private view is not listed", %{conn: conn} do
      owner = authed_user(:editor)
      other = authed_user(:editor)
      a_post("pv")

      CMS.create_saved_view!(%{name: "Owner only", params: %{"status" => "draft"}},
        actor: owner,
        tenant: Accounts.default_org_id()
      )

      {:ok, _lv, html} = conn |> log_in(other) |> live(~p"/editor")
      refute html =~ "Owner only"
    end

    test "a view whose category is gone links to what it would still show", %{conn: conn} do
      editor = authed_user(:editor)
      a_post("st")

      view =
        CMS.create_saved_view!(
          %{name: "Stale", params: %{"status" => "draft", "category" => Ecto.UUID.generate()}},
          actor: editor,
          tenant: Accounts.default_org_id()
        )

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

      assert lv |> element("#view-#{view.id}") |> render() =~ ~s(href="/editor?category=)

      lv |> element("#view-#{view.id}") |> render_click()
      assert_patch(lv)
      assert render(lv) =~ "Category: a deleted category"
    end
  end
end
