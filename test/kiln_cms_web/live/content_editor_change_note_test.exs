defmodule KilnCMSWeb.ContentEditorChangeNoteTest do
  @moduledoc """
  The editor's change note (`KilnCMS.CMS.ChangeNotes`): on a type the site
  lists, a draft's Save and Publish changes are refused until the editor says
  why, the note lands on that edit's version, and History shows it.
  """
  # `async: false`: the setting is one row per organization, and every test
  # here uses the default org.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.EditorialSettings

  @password "password123456"

  defp authed_user(role) do
    email = "note-ed-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

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

  defp slug, do: "note-ed-#{System.unique_integer([:positive])}"
  defp org, do: KilnCMS.Accounts.default_org_id()
  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp ask_for(admin, types),
    do:
      {:ok, _} = EditorialSettings.save(%{change_note_types: types}, actor: admin, tenant: org())

  defp open(conn, user, page),
    do: conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")

  defp notes(page, action) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id and &1.version_action_name == action))
    |> Enum.map(& &1.change_note)
    |> Enum.reject(&is_nil/1)
  end

  defp type_note(lv, note),
    do: lv |> element("#change-note-input") |> render_change(%{"_kiln_change_note" => note})

  defp save(lv, title, note \\ nil) do
    params = %{"form" => %{"title" => title}}
    params = if note, do: Map.put(params, "_kiln_change_note", note), else: params
    lv |> form("#page-editor") |> render_submit(params)
  end

  setup do
    %{admin: authed_user(:admin)}
  end

  test "a type the site does not list shows no input", %{conn: conn, admin: admin} do
    page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
    {:ok, lv, _html} = open(conn, admin, page)

    refute has_element?(lv, "#change-note")
  end

  test "a draft's Save on a listed type asks why, then stores the note",
       %{conn: conn, admin: admin} do
    ask_for(admin, ["page"])
    page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
    {:ok, lv, _html} = open(conn, admin, page)

    assert has_element?(lv, "#change-note", "Asked when you save")

    save(lv, "Renamed")
    assert has_element?(lv, "#change-note-error")
    assert reload(page).title == "Draft"

    type_note(lv, "matches the source's title")
    refute has_element?(lv, "#change-note-error")

    save(lv, "Renamed", "matches the source's title")
    assert reload(page).title == "Renamed"
    assert notes(page, :update) == ["matches the source's title"]

    # Cleared once it landed, and shown in History.
    assert has_element?(lv, "#change-note-input[value='']")
    assert has_element?(lv, "[id^=version-note-]", "matches the source's title")
  end

  test "Publish changes on a listed type asks why, then stores the note",
       %{conn: conn, admin: admin} do
    page =
      %{title: "Live title", slug: slug()}
      |> CMS.create_page!(actor: admin)
      |> CMS.publish_page!(%{}, actor: admin)

    KilnCMS.DataCase.drain_oban()
    page = reload(page)
    ask_for(admin, ["page"])
    {:ok, lv, _html} = open(conn, admin, page)

    assert has_element?(lv, "#change-note", "Asked when you publish your changes")

    lv
    |> form("#page-editor")
    |> render_change(%{"form" => %{"title" => "Dose corrected"}, "_target" => ["form", "title"]})

    send(lv.pid, :autosave)
    render(lv)

    lv |> element("#publish-changes") |> render_click()
    assert has_element?(lv, "#change-note-error")
    assert reload(page).title == "Live title"

    type_note(lv, "dose corrected per the 2020 pharmacopoeia")
    lv |> element("#publish-changes") |> render_click()

    assert reload(page).title == "Dose corrected"
    assert notes(page, :publish_changes) == ["dose corrected per the 2020 pharmacopoeia"]
  end
end
