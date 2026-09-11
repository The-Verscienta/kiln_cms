defmodule KilnCMSWeb.ContentEditorWorkingCopyTest do
  @moduledoc """
  The content editor on a LIVE document (docs/working-copy.md): typing moves the
  working copy alone, the pill turns to "Live · draft" and the primary button to
  "Publish changes"; the menu offers "Discard the changes"; settings still save
  through Save and go live at once, without touching the text.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.WorkingCopy

  @password "password123456"

  defp authed_user(role) do
    email = "wc-live-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "wc-live-#{System.unique_integer([:positive])}"

  defp live_page(admin) do
    page =
      CMS.create_page!(
        %{
          title: "Live title",
          slug: slug(),
          blocks: [%{"_type" => "heading", "text" => "Published heading"}]
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    reload(page)
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp heading_texts(blocks) do
    blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> Enum.map(fn %KilnCMS.Blocks.Heading{text: text} -> text end)
  end

  defp open(conn, user, page),
    do: conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")

  defp type_title(lv, title) do
    lv
    |> form("#page-editor")
    |> render_change(%{"form" => %{"title" => title}, "_target" => ["form", "title"]})
  end

  # Fire the debounce the way the timer would.
  defp autosave(lv) do
    send(lv.pid, :autosave)
    render(lv)
  end

  test "typing moves the working copy alone, and the chrome says so", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))

    {:ok, lv, html} = open(conn, editor, page)
    assert html =~ "Published"
    refute html =~ "Live · draft"
    refute has_element?(lv, "#publish-changes")

    type_title(lv, "Edited title")
    html = autosave(lv)

    # The row: readers' text untouched, the copy stamped.
    saved = reload(page)
    assert saved.title == "Live title"
    assert heading_texts(saved.blocks) == ["Published heading"]
    assert saved.working_title == "Edited title"
    assert heading_texts(saved.working_blocks) == ["Published heading"]
    assert WorkingCopy.pending?(saved)

    # The chrome: pill, primary button, menu, save line.
    assert html =~ "Live · draft"
    assert has_element?(lv, "#publish-changes", "Publish changes")
    assert has_element?(lv, "#live-draft-menu button", "Discard the changes")
    assert html =~ "Saved to the working copy"

    # The editor keeps showing the working copy, not the published title.
    assert has_element?(lv, ~s(input[name="form[title]"][value="Edited title"]))
  end

  test "Publish changes hands the working copy over, same URL and date", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))
    {:ok, lv, _html} = open(conn, editor, page)

    type_title(lv, "Corrected title")
    autosave(lv)

    # A second edit still waiting for the debounce goes out too.
    type_title(lv, "Corrected title, final")
    html = lv |> element("#publish-changes") |> render_click()

    published = reload(page)
    assert published.title == "Corrected title, final"
    assert published.published_at == page.published_at
    assert published.slug == page.slug
    refute WorkingCopy.pending?(published)

    assert html =~ "Published your changes."
    refute html =~ "Live · draft"
    refute has_element?(lv, "#publish-changes")
    assert has_element?(lv, ~s(input[name="form[title]"][value="Corrected title, final"]))
  end

  test "Discard the changes puts the published text back", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))
    {:ok, lv, _html} = open(conn, editor, page)

    type_title(lv, "Thrown away")
    autosave(lv)
    assert WorkingCopy.pending?(reload(page))

    html = lv |> element("#live-draft-menu button", "Discard the changes") |> render_click()

    discarded = reload(page)
    assert discarded.title == "Live title"
    refute WorkingCopy.pending?(discarded)

    assert html =~ "the published text is back"
    refute html =~ "Live · draft"
    assert has_element?(lv, ~s(input[name="form[title]"][value="Live title"]))

    # Kept as a version, as promised.
    assert CMS.list_page_versions!(actor: editor, tenant: page.org_id)
           |> Enum.any?(
             &(&1.version_source_id == page.id and &1.changes["working_title"] == "Thrown away")
           )
  end

  test "Save writes settings live and leaves the text to the working copy", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))
    {:ok, lv, _html} = open(conn, editor, page)

    type_title(lv, "Still a draft")
    autosave(lv)

    # A setting: no autosave, a dirty flag, then Save.
    html =
      lv
      |> form("#page-editor")
      |> render_change(%{
        "form" => %{"seo_title" => "Search title"},
        "_target" => ["form", "seo_title"]
      })

    assert html =~ "Unsaved changes"

    html = lv |> form("#page-editor") |> render_submit()
    assert html =~ "Saved."
    refute html =~ "Unsaved changes"

    saved = reload(page)
    # The setting went live at once …
    assert saved.seo_title == "Search title"
    # … the published text did not move, and neither did the working copy.
    assert saved.title == "Live title"
    assert heading_texts(saved.blocks) == ["Published heading"]
    assert saved.working_title == "Still a draft"
    assert WorkingCopy.pending?(saved)
    refute saved.search_text =~ "Still a draft"

    # And the editor still shows the working copy.
    assert has_element?(lv, ~s(input[name="form[title]"][value="Still a draft"]))
    assert has_element?(lv, "#publish-changes")
  end

  test "Save flushes a text edit still waiting for the debounce into the copy", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))
    {:ok, lv, _html} = open(conn, editor, page)

    type_title(lv, "Typed then saved")
    lv |> form("#page-editor") |> render_submit()

    saved = reload(page)
    assert saved.title == "Live title"
    assert saved.working_title == "Typed then saved"
  end

  test "a title typed back to the published one is no working copy", %{conn: conn} do
    editor = authed_user(:editor)
    page = live_page(authed_user(:admin))
    {:ok, lv, _html} = open(conn, editor, page)

    type_title(lv, "Edited")
    autosave(lv)
    assert WorkingCopy.pending?(reload(page))

    type_title(lv, "Live title")
    html = autosave(lv)

    refute WorkingCopy.pending?(reload(page))
    refute html =~ "Live · draft"
  end

  test "the content list marks a live record edited since publishing", %{conn: conn} do
    admin = authed_user(:admin)
    page = live_page(admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor?status=published")
    refute html =~ "edited since publishing"

    {:ok, _} =
      CMS.save_page_working_copy(page, %{working_title: "Ahead", working_blocks: page.blocks},
        actor: admin,
        tenant: page.org_id
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor?status=published")
    assert html =~ "edited since publishing"
  end

  test "the signed-in preview shows the working copy and says so", %{conn: conn} do
    admin = authed_user(:admin)
    page = live_page(admin)

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/preview/page/#{page.id}")
    assert html =~ "Preview of the published text"
    assert html =~ "Live title"

    {:ok, _} =
      CMS.save_page_working_copy(
        page,
        %{
          working_title: "Working title",
          working_blocks: [%{"_type" => "heading", "text" => "Working heading"}]
        },
        actor: admin,
        tenant: page.org_id
      )

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/preview/page/#{page.id}")
    assert html =~ "Previewing unpublished changes"
    assert html =~ "Working title"
    assert html =~ "Working heading"
    refute html =~ "Published heading"

    # Readers still get the published page.
    assert CMS.get_published_page_by_slug!(page.slug, page.locale).title == "Live title"
  end
end
