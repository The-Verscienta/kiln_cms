defmodule KilnCMSWeb.ContentEditorUrlSettingsTest do
  @moduledoc """
  Canvas first: the slug, path alias and redirects list live in the inspector's
  Settings → URL section rather than between the title and the blocks. Moving
  them must not move them out of the editor form, hide their errors from a
  writer looking at the canvas, or stop them marking the draft dirty.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "url-settings-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page, query \\ "") do
    {:ok, lv, _html} =
      conn |> log_in(user) |> live("/editor/content/page/#{page.id}#{query}")

    lv
  end

  defp draft(editor) do
    n = System.unique_integer([:positive])
    CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
  end

  @settings_tab ~s{button[role="tab"][phx-value-tab="settings"]}

  setup %{conn: conn} do
    editor = authed_user(:editor)
    page = draft(editor)
    %{conn: conn, editor: editor, page: page}
  end

  test "the URL inputs render in Settings → URL, inside the editor form",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)

    # Descendants of the form itself — a phx-change on them lands on the
    # editor's `validate`, and a submit carries them.
    assert has_element?(lv, ~s{form#page-editor #inspector-url input[name="form[slug]"]})
    assert has_element?(lv, ~s{form#page-editor #inspector-url input[name="form[path_alias]"]})

    # Exactly once: nothing left behind in the canvas column.
    html = render(lv)
    assert length(Regex.scan(~r/name="form\[slug\]"/, html)) == 1
    assert length(Regex.scan(~r/name="form\[path_alias\]"/, html)) == 1

    # The address is still on screen under the title, with a way to edit it.
    assert has_element?(lv, "#url-summary", "/#{page.slug}")
    assert has_element?(lv, ~s{#url-summary button#edit-url[phx-click="edit_url"]})
  end

  test "the line under the title follows the auto-derived slug live",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)

    render_change(lv, "validate", %{
      "form" => %{"title" => "A Guide to the Kiln", "slug" => page.slug},
      "_target" => ["form", "title"]
    })

    assert has_element?(lv, "#url-summary", "/guide-kiln")
    assert has_element?(lv, ~s{#inspector-url input[name="form[slug]"][value="guide-kiln"]})
  end

  test "Edit URL opens Settings and focuses the slug", %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)
    refute has_element?(lv, ~s{#{@settings_tab}[aria-selected="true"]})

    lv |> element("#edit-url") |> render_click()

    assert has_element?(lv, ~s{#{@settings_tab}[aria-selected="true"]})
    assert_push_event(lv, "kiln:focus-field", %{field: "slug"})
  end

  test "a ?focus=slug deep link lands on the Settings tab",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page, "?focus=slug")
    assert has_element?(lv, ~s{#{@settings_tab}[aria-selected="true"]})
  end

  test "editing the slug from Settings still marks the draft dirty",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)
    assert has_element?(lv, ~s{form#page-editor[data-dirty="false"]})

    # Through the editor form itself: `form/3` refuses a field the form does
    # not contain, so this also proves the moved input still belongs to it.
    lv
    |> form("#page-editor", %{"form" => %{"slug" => "my-own-slug"}})
    |> render_change(%{"_target" => ["form", "slug"]})

    assert has_element?(lv, ~s{form#page-editor[data-dirty="true"]})
    assert has_element?(lv, "#url-summary", "/my-own-slug")
  end

  test "a save refused on the URL says so and jumps to the field",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)

    html = render_submit(lv, "save", %{"form" => %{"path_alias" => "Not A Path"}})

    assert html =~ "The URL needs fixing"
    assert has_element?(lv, ~s{#{@settings_tab}[aria-selected="true"]})
    assert has_element?(lv, "#{@settings_tab} span.bg-error")
    assert has_element?(lv, "#url-summary", "Needs attention")
    assert has_element?(lv, "#inspector-url", "must look like /lowercase/segments-like-this")
    assert_push_event(lv, "kiln:focus-field", %{field: "path_alias"})

    # Nothing was written.
    assert CMS.get_page!(page.id, actor: editor).path_alias in [nil, ""]
  end

  test "a save refused elsewhere keeps the generic message and the tab",
       %{conn: conn, editor: editor, page: page} do
    lv = open_editor(conn, editor, page)

    html = render_submit(lv, "save", %{"form" => %{"title" => ""}})

    assert html =~ "Please fix the errors below."
    refute html =~ "The URL needs fixing"
    refute has_element?(lv, ~s{#{@settings_tab}[aria-selected="true"]})
    refute has_element?(lv, "#url-summary", "Needs attention")
  end
end
