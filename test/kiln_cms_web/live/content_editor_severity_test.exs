defmodule KilnCMSWeb.ContentEditorSeverityTest do
  @moduledoc """
  The editor's change-severity question (`KilnCMS.CMS.Severity`): a published
  edit that touches a field the site lists as safety-relevant is not made until
  the editor says how much it matters; an edit that touches none never asks.
  """
  # `async: false`: the safety-field list is one cached row per organization, and
  # every test here uses the default org.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "sev-ed-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "sev-ed-#{System.unique_integer([:positive])}"

  defp list_safety(admin, fields) do
    CMS.save_site_safety_fields!(%{fields: fields},
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

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

  defp open(conn, user, page, kind \\ "page"),
    do: conn |> log_in(user) |> live(~p"/editor/content/#{kind}/#{page.id}")

  defp type_title(lv, title) do
    lv
    |> form("#page-editor")
    |> render_change(%{"form" => %{"title" => title}, "_target" => ["form", "title"]})
  end

  defp autosave(lv) do
    send(lv.pid, :autosave)
    render(lv)
  end

  # The severities on the version rows the document has, oldest first.
  defp severities(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id}, :asc)
    |> Enum.map(& &1.change_severity)
    |> Enum.reject(&is_nil/1)
  end

  setup do
    %{admin: authed_user(:admin)}
  end

  test "Publish changes on a listed field asks first and writes nothing until answered",
       %{conn: conn, admin: admin} do
    # Published first: the setup publish is itself a first publish.
    page = live_page(admin)
    list_safety(admin, %{"page" => ["title"]})
    {:ok, lv, _html} = open(conn, admin, page)

    type_title(lv, "Dose corrected")
    autosave(lv)
    lv |> element("#publish-changes") |> render_click()

    assert has_element?(lv, "#severity-ask", "How much does this change matter?")
    assert has_element?(lv, "#severity-confirm[disabled]")
    refute has_element?(lv, ~s(#severity-ask [aria-pressed="true"]))

    # Nothing went live, and nothing was recorded.
    assert reload(page).title == "Live title"
    assert severities(page) == []

    # A forged confirm without an answer is refused, with the reason beside the
    # selector.
    lv |> render_click("severity_confirm", %{})
    assert has_element?(lv, "#severity-ask-error")
    assert reload(page).title == "Live title"
    assert severities(page) == []
  end

  test "the chosen severity is stored on the version it was chosen for",
       %{conn: conn, admin: admin} do
    # Published first: the setup publish is itself a first publish.
    page = live_page(admin)
    list_safety(admin, %{"page" => ["title"]})
    {:ok, lv, _html} = open(conn, admin, page)

    type_title(lv, "Dose corrected")
    autosave(lv)
    lv |> element("#publish-changes") |> render_click()
    lv |> element("#severity-critical") |> render_click()
    assert has_element?(lv, ~s(#severity-critical[aria-pressed="true"]))
    html = lv |> element("#severity-confirm") |> render_click()

    assert html =~ "Published your changes."
    refute has_element?(lv, "#severity-ask")
    assert reload(page).title == "Dose corrected"
    assert severities(page) == [:critical]
  end

  test "two consecutive publishes each carry their own severity", %{conn: conn, admin: admin} do
    # Published first: the setup publish is itself a first publish.
    page = live_page(admin)
    list_safety(admin, %{"page" => ["title"]})
    {:ok, lv, _html} = open(conn, admin, page)

    type_title(lv, "First correction")
    autosave(lv)
    lv |> element("#publish-changes") |> render_click()
    lv |> element("#severity-critical") |> render_click()
    lv |> element("#severity-confirm") |> render_click()

    type_title(lv, "Second correction")
    autosave(lv)
    lv |> element("#publish-changes") |> render_click()

    # The first answer is gone: the selector comes back empty.
    assert has_element?(lv, "#severity-ask")
    refute has_element?(lv, ~s(#severity-ask [aria-pressed="true"]))
    assert has_element?(lv, "#severity-confirm[disabled]")

    lv |> element("#severity-routine") |> render_click()
    lv |> element("#severity-confirm") |> render_click()

    assert reload(page).title == "Second correction"
    assert severities(page) == [:critical, :routine]
  end

  test "a publish touching no listed field shows no selector and succeeds",
       %{conn: conn, admin: admin} do
    # Published first: the setup publish is itself a first publish.
    page = live_page(admin)
    list_safety(admin, %{"page" => ["blocks"]})
    {:ok, lv, _html} = open(conn, admin, page)

    type_title(lv, "Only the title")
    autosave(lv)
    html = lv |> element("#publish-changes") |> render_click()

    refute has_element?(lv, "#severity-ask")
    assert html =~ "Published your changes."
    assert reload(page).title == "Only the title"
    assert severities(page) == []
  end

  test "a first publish with a listed field filled in asks", %{conn: conn, admin: admin} do
    list_safety(admin, %{"page" => ["title"]})

    draft =
      CMS.create_page!(
        %{title: "Draft title", slug: slug(), blocks: [%{"_type" => "heading", "text" => "H"}]},
        actor: admin
      )

    {:ok, lv, _html} = open(conn, admin, draft)

    lv |> element(~s(button[phx-value-action="publish"])) |> render_click()
    assert has_element?(lv, "#severity-ask")
    assert reload(draft).state == :draft

    lv |> element("#severity-notable") |> render_click()
    lv |> element("#severity-confirm") |> render_click()

    assert reload(draft).state == :published
    assert severities(draft) == [:notable]
  end

  test "a type with no listed fields never asks", %{conn: conn, admin: admin} do
    list_safety(admin, %{"page" => ["title"]})

    post =
      CMS.create_post!(
        %{title: "Post", slug: slug(), blocks: [%{"_type" => "heading", "text" => "H"}]},
        actor: admin
      )

    post = CMS.publish_post!(post, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    {:ok, lv, _html} = open(conn, admin, post, "post")
    lv |> form("#post-editor") |> render_change(%{"form" => %{"title" => "Post, edited"}})
    send(lv.pid, :autosave)
    render(lv)
    html = lv |> element("#publish-changes") |> render_click()

    refute has_element?(lv, "#severity-ask")
    assert html =~ "Published your changes."
  end
end
