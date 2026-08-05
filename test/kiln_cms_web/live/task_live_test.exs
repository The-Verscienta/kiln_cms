defmodule KilnCMSWeb.TaskLiveTest do
  @moduledoc """
  The editorial workload view (`/editor/tasks`, #501): "my tasks" by
  default, plus a team-wide workload view every editor can already read
  (task's policy is editor-wide, same as comments).
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "tasklive-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "tasklive-#{System.unique_integer([:positive])}"

  test "my tasks lists only the viewer's own open tasks", %{conn: conn} do
    editor = authed_user(:editor)
    other = authed_user(:editor)

    mine = CMS.create_page!(%{title: "Mine to do", slug: slug()}, actor: editor)
    theirs = CMS.create_page!(%{title: "Not mine", slug: slug()}, actor: editor)

    CMS.assign_task!(
      %{content_type: "page", content_id: mine.id, assignee_id: editor.id, note: "please fix"},
      actor: editor
    )

    CMS.assign_task!(
      %{content_type: "page", content_id: theirs.id, assignee_id: other.id},
      actor: editor
    )

    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/tasks")

    assert html =~ mine.title
    assert html =~ "please fix"
    refute html =~ theirs.title
  end

  test "an empty my-tasks queue says so", %{conn: conn} do
    editor = authed_user(:editor)
    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/tasks")

    assert html =~ "No open tasks assigned to you."
  end

  test "team workload groups tasks by assignee", %{conn: conn} do
    editor = authed_user(:editor)
    alice = authed_user(:editor)
    bob = authed_user(:editor)

    page_a = CMS.create_page!(%{title: "For Alice", slug: slug()}, actor: editor)
    page_b = CMS.create_page!(%{title: "For Bob", slug: slug()}, actor: editor)

    CMS.assign_task!(%{content_type: "page", content_id: page_a.id, assignee_id: alice.id},
      actor: editor
    )

    CMS.assign_task!(%{content_type: "page", content_id: page_b.id, assignee_id: bob.id},
      actor: editor
    )

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/tasks")
    html = lv |> element("a", "Team workload") |> render_click()

    assert html =~ page_a.title
    assert html =~ page_b.title
  end

  test "marking a task done removes it from the list", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Finish this", slug: slug()}, actor: editor)

    CMS.assign_task!(%{content_type: "page", content_id: page.id, assignee_id: editor.id},
      actor: editor
    )

    {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/tasks")
    assert html =~ page.title

    html = lv |> element("button", "Mark done") |> render_click()
    refute html =~ page.title
  end

  test "an overdue task is flagged", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Overdue item", slug: slug()}, actor: editor)

    CMS.assign_task!(
      %{
        content_type: "page",
        content_id: page.id,
        assignee_id: editor.id,
        due_on: Date.add(Date.utc_today(), -3)
      },
      actor: editor
    )

    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/tasks")

    assert html =~ "Overdue"
  end
end
