defmodule KilnCMSWeb.ContentEditorCompareTest do
  @moduledoc """
  Side-by-side version comparison in the content editor (#467): pick two entries
  in the version-history panel — a saved version or the working draft — and see
  what changed between them, with Restore reachable from the comparison itself.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "cmp-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    lv
  end

  defp slug, do: "cmp-#{System.unique_integer([:positive])}"

  defp versions(page, actor) do
    CMS.list_page_versions!(actor: actor)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  defp pick(lv, id), do: render_click(lv, "toggle_compare", %{"version_id" => id})

  # Matched as an attribute rather than by regex over the markup: the button's
  # own class carries `disabled:opacity-50`, which a substring match would hit
  # whether or not the button is actually disabled.
  defp compare_disabled?(lv),
    do: has_element?(lv, ~s{button[phx-click="open_compare"][disabled]})

  defp edited_page(actor) do
    page =
      CMS.create_page!(
        %{
          title: "Original title",
          slug: slug(),
          seo_description: "The original description, long enough to diff word by word.",
          blocks: [%{type: :heading, content: "Kept heading", order: 0}]
        },
        actor: actor
      )

    page =
      CMS.update_page!(
        page,
        %{
          title: "Revised title",
          seo_description: "The revised description, long enough to diff word by word."
        },
        actor: actor
      )

    {page, versions(page, actor)}
  end

  test "comparing two versions reports the fields that changed", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)

    pick(lv, first.id)
    pick(lv, second.id)

    html = render_click(lv, "open_compare", %{})

    assert html =~ "Compare versions"
    assert html =~ "Title"
    assert html =~ "Original title"
    assert html =~ "Revised title"

    # Word-level runs: only the word that actually changed is marked.
    assert html =~ "<ins"
    assert html =~ "revised"
    refute html =~ ~r/<del[^>]*>description/
  end

  test "the working draft can be one side of the comparison", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, _second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)

    pick(lv, first.id)
    pick(lv, "current")

    html = render_click(lv, "open_compare", %{})

    assert html =~ "Current draft"
    assert html =~ "Revised title"
  end

  test "block additions, removals and moves are reported as such", %{conn: conn} do
    editor = authed_user(:editor)

    page =
      CMS.create_page!(
        %{
          title: "Blocks",
          slug: slug(),
          blocks: [
            %{type: :heading, content: "First", order: 0},
            %{type: :heading, content: "Second", order: 1}
          ]
        },
        actor: editor
      )

    [%{"value" => %{"id" => first_id}}, %{"value" => %{"id" => second_id}}] =
      KilnCMS.CMS.VersionSnapshot.current(page)["blocks"]

    # Reorder and append: the two originals keep their ids, so the diff must read
    # this as a move plus an insert, not as three replacements.
    page =
      CMS.update_page!(
        page,
        %{
          blocks: [
            %{_type: "heading", id: second_id, text: "Second", level: 2},
            %{_type: "heading", id: first_id, text: "First", level: 2},
            %{_type: "heading", text: "Third", level: 2}
          ]
        },
        actor: editor
      )

    [before_edit, after_edit] = versions(page, editor)

    lv = open_editor(conn, editor, page)
    pick(lv, before_edit.id)
    pick(lv, after_edit.id)

    html = render_click(lv, "open_compare", %{})

    assert html =~ "Content blocks"
    assert html =~ "Added"
    assert html =~ "Moved"
  end

  test "a third pick retires the older selection rather than being ignored", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: editor)
    page = CMS.update_page!(page, %{title: "Two"}, actor: editor)
    page = CMS.update_page!(page, %{title: "Three"}, actor: editor)

    [first, second, third] = versions(page, editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, second.id)
    pick(lv, third.id)

    html = render_click(lv, "open_compare", %{})

    # first was dropped, so the comparison spans second → third.
    assert html =~ "Two"
    assert html =~ "Three"
    refute html =~ ">One<"
  end

  test "picking the same entry twice clears it and disables Compare", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, second.id)
    refute compare_disabled?(lv)

    pick(lv, second.id)
    assert compare_disabled?(lv)
  end

  test "comparing fewer than two entries flashes rather than crashing", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, _second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)

    html = render_click(lv, "open_compare", %{})

    assert html =~ "Couldn&#39;t compare those versions."
    refute html =~ "Compare versions"
  end

  test "a version id from another record is refused", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, _second]} = edited_page(editor)
    other = CMS.create_page!(%{title: "Theirs", slug: slug()}, actor: editor)
    [other_version | _] = versions(other, editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, other_version.id)

    html = render_click(lv, "open_compare", %{})

    assert html =~ "Couldn&#39;t compare those versions."
  end

  test "restoring from inside the comparison applies it and closes the modal", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, second.id)
    render_click(lv, "open_compare", %{})

    html = render_click(lv, "restore", %{"version_id" => first.id})

    assert html =~ "Restored that version."
    refute html =~ "Compare versions"

    assert CMS.get_page!(page.id, actor: editor).title == "Original title"
  end

  test "closing the comparison leaves the picks alone", %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, second.id)
    render_click(lv, "open_compare", %{})

    html = render_click(lv, "close_compare", %{})

    refute html =~ "Compare versions"
    # Both toggles are still checked, so Compare reopens without re-picking.
    assert html =~ ~s{aria-checked="true"}
    refute compare_disabled?(lv)
  end

  test "an open comparison against the draft follows the record when it is saved",
       %{conn: conn} do
    editor = authed_user(:editor)
    {page, [first, _second]} = edited_page(editor)

    lv = open_editor(conn, editor, page)
    pick(lv, first.id)
    pick(lv, "current")
    html = render_click(lv, "open_compare", %{})
    assert html =~ "Revised title"

    # A save lands while the modal is open — a pending autosave, or a
    # collaborator's write pulled in by a reload. The "Current draft" side must
    # follow it; leaving the old diff up describes a document that no longer
    # exists, which is exactly what the compare path refuses to do elsewhere.
    CMS.update_page!(page, %{title: "Saved while comparing"}, actor: editor)
    html = render_click(lv, "reload_conflict", %{})

    assert html =~ "Compare versions"
    assert html =~ "Saved while comparing"
  end

  # #712. The labels used to be a second copy of `field_order/0` — the same
  # nineteen names in the same order, independently maintained. The gate below
  # caught a *missing* label; nothing caught the ordering, so a name added to the
  # labels but not to `field_order/0` sorted alphabetically into the "rest"
  # bucket instead of where its author meant it.
  #
  # One list drives both now, and the drift is a compile error in both
  # directions. This asserts the relationship the build enforces, so the reason
  # for it survives in something readable.
  test "the labels are the ordered fields, in that order" do
    assert KilnCMSWeb.VersionDiffComponents.labelled_fields() ==
             KilnCMS.CMS.VersionFields.field_order()
  end

  test "every field the diff can report has a translated label" do
    # The fall-through humanizes the attribute name and ships it untranslated
    # with nothing going red, so this is the gate on that: a new content
    # attribute lands in the compare modal automatically and must come with a
    # label rather than an English string in a Spanish UI.
    labelled = KilnCMSWeb.VersionDiffComponents.labelled_fields()

    missing =
      for resource <- [KilnCMS.CMS.Page, KilnCMS.CMS.Post, KilnCMS.CMS.Entry],
          field <- KilnCMS.CMS.VersionDiff.diffable_fields(resource),
          field not in labelled,
          uniq: true,
          do: field

    assert missing == [],
           "add these to @field_labels in KilnCMSWeb.VersionDiffComponents: " <>
             inspect(missing)
  end
end
