defmodule KilnCMSWeb.ContentEditorRedirectsTest do
  @moduledoc """
  The redirects standing under a record's address, listed in the content
  editor directly beneath the slug / path-alias fields: a published rename
  lists the vacated path the moment the save lands, each row has a Delete
  that retires the 301 (as an editor, not only an admin), and a record with
  nothing standing under it shows no list at all.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Slugs

  @password "password123456"

  defp authed_user(role, grants \\ %{}) do
    email = "editor-redirects-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        grants
      )
    )

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

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "A page", slug: "er-pg-#{uniq()}", state: :draft}, attrs)
    )
  end

  defp open_editor(conn, user, page) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    lv
  end

  defp page_path(page), do: Slugs.public_path_for(ContentTypes.get("page"), page)

  defp redirect_to(page, path) do
    CMS.create_redirect!(
      %{path: path, locale: page.locale, target_type: "page", target_id: page.id},
      authorize?: false,
      tenant: page.org_id
    )
  end

  defp redirects_for(page) do
    CMS.list_redirects!(
      authorize?: false,
      tenant: page.org_id,
      query: [filter: [target_type: "page", target_id: page.id]]
    )
  end

  test "a published rename lists the vacated path under the slug field", %{conn: conn} do
    admin = authed_user(:admin)
    page = page(%{state: :published})
    old_path = page_path(page)
    lv = open_editor(conn, admin, page)

    refute has_element?(lv, "#slug-redirects")

    render_submit(lv, "save", %{"form" => %{"slug" => "#{page.slug}-renamed"}})

    assert [redirect] = redirects_for(page)
    assert redirect.path == old_path

    row = "#slug-redirect-#{redirect.id}"
    assert has_element?(lv, "#{row} .font-mono", old_path)
    assert has_element?(lv, "#{row} .font-mono", "#{old_path}-renamed")
    assert has_element?(lv, row, "since #{Calendar.strftime(redirect.inserted_at, "%Y-%m-%d")}")
    assert has_element?(lv, ~s{#{row} button[phx-click="delete_redirect"][data-confirm]})
  end

  test "Delete retires the redirect, as an editor who may write the record", %{conn: conn} do
    editor = authed_user(:editor)
    page = page(%{state: :published})
    redirect = redirect_to(page, "/#{page.slug}-before")
    lv = open_editor(conn, editor, page)

    row = "#slug-redirect-#{redirect.id}"
    assert has_element?(lv, "#{row} .font-mono", "/#{page.slug}-before")

    lv
    |> element(~s{#{row} button[phx-click="delete_redirect"]})
    |> render_click()

    refute has_element?(lv, "#slug-redirects")
    assert render(lv) =~ "Redirect deleted."
    assert redirects_for(page) == []
  end

  test "a row that vanished underneath the panel reloads the list instead of deleting",
       %{conn: conn} do
    admin = authed_user(:admin)
    page = page(%{state: :published})
    redirect = redirect_to(page, "/#{page.slug}-gone")
    lv = open_editor(conn, admin, page)

    # Pruned from /editor/redirects (or by another editor) while this panel
    # was open: the button still names it.
    CMS.destroy_redirect!(redirect, authorize?: false, tenant: page.org_id)

    render_click(lv, "delete_redirect", %{"id" => redirect.id})

    assert render(lv) =~ "Couldn&#39;t delete that redirect."
    refute has_element?(lv, "#slug-redirects")
  end

  test "only a row standing under THIS record is reachable from the panel", %{conn: conn} do
    admin = authed_user(:admin)
    page = page(%{state: :published})
    other = page(%{state: :published})
    foreign = redirect_to(other, "/#{other.slug}-old")
    lv = open_editor(conn, admin, page)

    # An admin could delete this row from /editor/redirects — but not by
    # naming it from another record's editor.
    render_click(lv, "delete_redirect", %{"id" => foreign.id})

    assert [_still_there] = redirects_for(other)
  end

  test "a reader who may open but not write the record sees the rows without Delete",
       %{conn: conn} do
    # An editor scoped to author only "post" can read pages but not write one.
    reader = authed_user(:editor, %{editable_types: ["post"], readable_types: []})
    page = page(%{state: :published})
    redirect = redirect_to(page, "/#{page.slug}-old")
    lv = open_editor(conn, reader, page)

    row = "#slug-redirect-#{redirect.id}"
    assert has_element?(lv, "#{row} .font-mono", "/#{page.slug}-old")
    refute has_element?(lv, "#{row} button")

    # And the handler refuses a hand-rolled event too — the policy, not the
    # template, is the gate.
    render_click(lv, "delete_redirect", %{"id" => redirect.id})
    assert [_still_there] = redirects_for(page)
  end

  test "a draft with nothing standing under it shows no list", %{conn: conn} do
    editor = authed_user(:editor)
    page = page(%{})
    lv = open_editor(conn, editor, page)

    refute has_element?(lv, "#slug-redirects")

    # A draft rename records nothing (its URL was never public) — still no list.
    render_submit(lv, "save", %{"form" => %{"slug" => "#{page.slug}-moved"}})

    assert redirects_for(page) == []
    refute has_element?(lv, "#slug-redirects")
  end
end
