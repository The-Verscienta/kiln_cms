defmodule KilnCMSWeb.ContentEditorRestorePreviewTest do
  @moduledoc """
  Restoring a version goes through a preview (#2294): both Restore buttons post
  "restore", which only shows what would change (including the custom keys the
  restore would discard); "confirm_restore" writes, and "cancel_restore" leaves
  everything as it was. An actor whose restore the action would refuse never
  sees a confirm.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "rprev-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

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

  defp open_editor(conn, user, page) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    lv
  end

  defp slug, do: "rprev-#{System.unique_integer([:positive])}"

  defp versions(page, actor) do
    CMS.list_page_versions!(actor: actor)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  defp define_field!(admin, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)

  # A page whose FIRST version carries `price`, whose definition is retired
  # since, and which gained `badge` after that version.
  defp page_with_history do
    admin = authed_user(:admin)
    price = define_field!(admin, %{name: "price", label: "Price"})

    page =
      CMS.create_page!(
        %{title: "Original", slug: slug(), custom_fields: %{"price" => "9"}},
        actor: admin
      )

    [first | _] = versions(page, admin)

    define_field!(admin, %{name: "badge", label: "Badge"})

    page =
      CMS.update_page!(
        page,
        %{title: "Revised", custom_fields: %{"price" => "9", "badge" => "new"}},
        actor: admin
      )

    CMS.destroy_field_definition!(price, actor: admin)

    {admin, page, first}
  end

  defp restore_button(version_id),
    do: ~s{button[phx-click="restore"][phx-value-version_id="#{version_id}"]}

  test "the history list's Restore previews instead of restoring, with no browser confirm",
       %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    refute has_element?(lv, restore_button(first.id) <> "[data-confirm]")

    lv |> element(restore_button(first.id)) |> render_click()

    assert has_element?(lv, "#restore-preview-dialog")
    assert has_element?(lv, "#confirm-restore")
    # Nothing was written.
    assert CMS.get_page!(page.id, actor: admin).title == "Revised"
  end

  test "the preview lists a retired key to be discarded and a key added since", %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    html = lv |> element(restore_button(first.id)) |> render_click()

    # `price` has no definition any more: named raw, in the discard list.
    assert has_element?(lv, ~s{#restore-preview-dropped [data-dropped-key="price"]})
    # `badge` was added after that version: the restore removes it, by label.
    assert has_element?(lv, ~s{#restore-preview-dialog [data-custom-field="badge"]})
    assert html =~ "Badge"
    assert html =~ "Revised"
  end

  test "confirming restores what the preview showed and closes it", %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    lv |> element(restore_button(first.id)) |> render_click()
    html = lv |> element("#confirm-restore") |> render_click()

    assert html =~ "Restored that version."
    refute has_element?(lv, "#restore-preview-dialog")

    restored = CMS.get_page!(page.id, actor: admin)
    assert restored.title == "Original"
    refute Map.has_key?(restored.custom_fields, "badge")
    refute Map.has_key?(restored.custom_fields, "price")
  end

  test "cancelling writes nothing", %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    lv |> element(restore_button(first.id)) |> render_click()

    lv
    |> element(~s{#restore-preview-dialog button.btn[phx-click="cancel_restore"]})
    |> render_click()

    refute has_element?(lv, "#restore-preview-dialog")

    unchanged = CMS.get_page!(page.id, actor: admin)
    assert unchanged.title == "Revised"
    assert unchanged.custom_fields["badge"] == "new"
  end

  test "the compare modal's Restore goes through the same preview, and cancel returns to it",
       %{conn: conn} do
    {admin, page, first} = page_with_history()
    [_, second] = Enum.take(versions(page, admin), 2)
    lv = open_editor(conn, admin, page)

    render_click(lv, "toggle_compare", %{"version_id" => first.id})
    render_click(lv, "toggle_compare", %{"version_id" => second.id})
    render_click(lv, "open_compare", %{})

    refute has_element?(
             lv,
             "#version-compare-dialog " <> restore_button(first.id) <> "[data-confirm]"
           )

    lv |> element("#version-compare-dialog " <> restore_button(first.id)) |> render_click()

    assert has_element?(lv, "#restore-preview-dialog")
    refute has_element?(lv, "#version-compare-dialog")
    assert CMS.get_page!(page.id, actor: admin).title == "Revised"

    lv
    |> element(~s{#restore-preview-dialog button.btn[phx-click="cancel_restore"]})
    |> render_click()

    assert has_element?(lv, "#version-compare-dialog")
  end

  test "a confirm with no preview for that version does nothing", %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    render_click(lv, "confirm_restore", %{"version_id" => first.id})

    assert CMS.get_page!(page.id, actor: admin).title == "Revised"
  end

  test "a confirm after the schema moved re-shows the preview and writes nothing", %{conn: conn} do
    {admin, page, first} = page_with_history()
    lv = open_editor(conn, admin, page)

    lv |> element(restore_button(first.id)) |> render_click()
    assert has_element?(lv, ~s{#restore-preview-dropped [data-dropped-key="price"]})

    # `price` is defined again after the preview was drawn, so the restore would
    # no longer discard it: what was agreed to is not what would happen.
    define_field!(admin, %{name: "price", label: "Price"})

    html = render_click(lv, "confirm_restore", %{"version_id" => first.id})

    assert html =~ "That version changed since the preview. Review it again."
    assert has_element?(lv, "#restore-preview-dialog")
    assert has_element?(lv, "#confirm-restore")
    refute has_element?(lv, ~s{#restore-preview-dropped [data-dropped-key="price"]})

    unchanged = CMS.get_page!(page.id, actor: admin)
    assert unchanged.title == "Revised"
    assert unchanged.custom_fields["badge"] == "new"
  end

  test "a forged confirm for another version than the open preview writes nothing",
       %{conn: conn} do
    {admin, page, first} = page_with_history()
    [_, second] = Enum.take(versions(page, admin), 2)
    lv = open_editor(conn, admin, page)

    lv |> element(restore_button(first.id)) |> render_click()

    render_click(lv, "confirm_restore", %{"version_id" => second.id})

    # The preview for `first` is still the one open, and nothing was written.
    assert has_element?(lv, "#restore-preview-dialog")
    unchanged = CMS.get_page!(page.id, actor: admin)
    assert unchanged.title == "Revised"
    assert unchanged.custom_fields["badge"] == "new"
  end

  test "an editor with a field grant sees no enabled Restore button, and a forged event is refused",
       %{conn: conn} do
    {admin, page, first} = page_with_history()
    granted = authed_user(:editor, %{field_grants: %{"page" => ["title"]}})
    lv = open_editor(conn, granted, page)

    # The button is rendered disabled, with the reason, and carries no event.
    refute has_element?(lv, restore_button(first.id))

    assert has_element?(
             lv,
             ~s{button[disabled][title*="requires full field access"]},
             "Restore"
           )

    # A forged event is still refused by the handler.
    html = render_click(lv, "restore", %{"version_id" => first.id})
    assert html =~ "Restoring a version requires full field access"
    refute has_element?(lv, "#restore-preview-dialog")
    refute has_element?(lv, "#confirm-restore")

    # A forged confirm is refused the same way.
    render_click(lv, "confirm_restore", %{"version_id" => first.id})
    assert CMS.get_page!(page.id, actor: admin).title == "Revised"
  end

  test "an editor without a grant still gets an enabled Restore button", %{conn: conn} do
    {_admin, page, first} = page_with_history()
    editor = authed_user(:editor)
    lv = open_editor(conn, editor, page)

    assert has_element?(lv, restore_button(first.id))
    refute has_element?(lv, ~s{button[disabled]}, "Restore")
  end

  test "a viewer cannot reach the editor, so cannot reach the preview", %{conn: conn} do
    {_admin, page, _first} = page_with_history()
    viewer = authed_user(:viewer)

    assert {:error, _redirect} =
             conn |> log_in(viewer) |> live(~p"/editor/content/page/#{page.id}")
  end
end
