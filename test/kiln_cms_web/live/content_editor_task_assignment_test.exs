defmodule KilnCMSWeb.ContentEditorTaskAssignmentTest do
  @moduledoc """
  The content editor's Assignment panel (#501): assign/reassign/mark-done
  from the Settings tab, and the `?assign=1` deep link from the content
  list's "Assign" button.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "assign-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(actor) do
    CMS.create_page!(
      %{
        title: "Assignable #{System.unique_integer([:positive])}",
        slug: "assign-#{System.unique_integer([:positive])}"
      },
      actor: actor
    )
  end

  test "assigning a task from the editor lists it in the Assignment panel", %{conn: conn} do
    editor = authed_user(:editor)
    assignee = authed_user(:editor)
    page = page!(editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    render_click(lv, "task_assign_open")
    render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
    render_change(lv, "task_draft_change", %{"task_due_on" => "2026-09-01"})
    render_change(lv, "task_draft_change", %{"task_note" => "please review"})
    html = render_click(lv, "task_assign_submit")

    assert html =~ "please review"
    assert html =~ "Due 2026-09-01"

    assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
    assert task.assignee_id == assignee.id
  end

  test "marking a task done removes it from the panel", %{conn: conn} do
    editor = authed_user(:editor)
    page = page!(editor)

    CMS.assign_task!(%{content_type: "page", content_id: page.id, assignee_id: editor.id},
      actor: editor
    )

    {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")
    assert html =~ "Mark done"

    html = lv |> element("button", "Mark done") |> render_click()
    assert html =~ "No open tasks."
  end

  test "the ?assign=1 deep link from the content list opens the assign form", %{conn: conn} do
    editor = authed_user(:editor)
    page = page!(editor)

    {:ok, _lv, html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}?assign=1")

    assert html =~ "Assign to…"
    assert html =~ "phx-click=\"task_assign_submit\""
  end
end
