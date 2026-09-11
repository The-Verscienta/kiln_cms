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

  # A global viewer whose tier on `org` comes from the membership alone.
  defp member(org, role) do
    user = authed_user(:viewer)

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: role
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

  # #419: on a non-default org the roster is that org's editors/admins by
  # EFFECTIVE tier — members whose tier comes from their membership (all
  # global viewers here) — not global editors, and the write accepts exactly
  # who the picker offers.
  test "on a second org the picker lists that org's editors and admins", %{conn: conn} do
    site = KilnCMS.OrgFixtures.org("assign")
    other = KilnCMS.OrgFixtures.org("assign-other")
    editor = member(site, :editor)
    site_admin = member(site, :admin)
    site_viewer = member(site, :viewer)
    other_admin = member(other, :admin)
    # Membership-less: keeps its global role on the default org only.
    legacy_editor = authed_user(:editor)

    page =
      CMS.create_page!(
        %{title: "Org assign", slug: "assign-#{System.unique_integer([:positive])}"},
        actor: editor,
        tenant: site
      )

    {:ok, lv, _html} =
      conn |> org_conn(site) |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    render_click(lv, "task_assign_open")

    assert has_element?(lv, ~s(option[value="#{editor.id}"]))
    assert has_element?(lv, ~s(option[value="#{site_admin.id}"]))
    refute has_element?(lv, ~s(option[value="#{site_viewer.id}"]))
    refute has_element?(lv, ~s(option[value="#{other_admin.id}"]))
    refute has_element?(lv, ~s(option[value="#{legacy_editor.id}"]))

    render_change(lv, "task_draft_change", %{"task_assignee_id" => site_admin.id})
    render_click(lv, "task_assign_submit")

    assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor, tenant: site)
    assert task.assignee_id == site_admin.id
  end

  test "the ?assign=1 deep link from the content list opens the assign form", %{conn: conn} do
    editor = authed_user(:editor)
    page = page!(editor)

    {:ok, _lv, html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}?assign=1")

    assert html =~ "Assign to…"
    assert html =~ "phx-click=\"task_assign_submit\""
  end

  # #817 (follow-up to #501): closing the loop between "this needs review" and
  # "here's who owns reviewing it" — the Assignment panel is one click away
  # already, but submitting for review didn't surface it as part of that flow.
  describe "the reviewer-assignment prompt on submit-for-review (#817)" do
    test "submitting for review opens the Settings tab and the Assignment panel", %{conn: conn} do
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")
      refute html =~ "Assign to…"

      html = lv |> element("button", "Submit for review") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :in_review
      assert html =~ "Assign to…"
      assert html =~ "phx-click=\"task_assign_submit\""
    end

    test "the due date is prefilled a few days out, not left blank", %{conn: conn} do
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")
      html = lv |> element("button", "Submit for review") |> render_click()

      suggested = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
      assert html =~ ~s(value="#{suggested}")
    end

    test "the prompt is dismissable and assigns no one on its own", %{conn: conn} do
      editor = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")
      lv |> element("button", "Submit for review") |> render_click()

      html = lv |> element("button", "Cancel") |> render_click()
      refute html =~ "phx-click=\"task_assign_submit\""
      assert CMS.list_tasks_for!("page", page.id, actor: editor) == []
    end

    test "accepting the prompt assigns a reviewer through the normal path", %{conn: conn} do
      editor = authed_user(:editor)
      assignee = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")
      lv |> element("button", "Submit for review") |> render_click()

      render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
      render_click(lv, "task_assign_submit")

      assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
      assert task.assignee_id == assignee.id
    end

    test "a different workflow action does not open the prompt", %{conn: conn} do
      admin = authed_user(:admin)
      page = page!(admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

      html = lv |> element("button", "Publish") |> render_click()
      refute html =~ "Assign to…"
    end
  end

  # The per-task override (#818). Three values, not two: the blank option is
  # "whatever the site is set to", which has to survive as `nil` rather than
  # being dropped from the attrs or coerced to a boolean.
  describe "auto-complete-on-publish override" do
    test "defaults to inheriting the site, and the option names what that means",
         %{conn: conn} do
      editor = authed_user(:editor)
      assignee = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      html = render_click(lv, "task_assign_open")
      assert html =~ "On publish: complete it (site default)"

      render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
      render_click(lv, "task_assign_submit")

      assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
      assert is_nil(task.auto_complete_on_publish)
    end

    test "an explicit opt-out is stored and shown on the row", %{conn: conn} do
      editor = authed_user(:editor)
      assignee = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      render_click(lv, "task_assign_open")
      render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
      render_change(lv, "task_draft_change", %{"task_auto_complete" => "false"})
      html = render_click(lv, "task_assign_submit")

      assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
      assert task.auto_complete_on_publish == false
      assert html =~ "Stays open when this publishes"
    end

    test "an explicit opt-in is stored", %{conn: conn} do
      editor = authed_user(:editor)
      assignee = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      render_click(lv, "task_assign_open")
      render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
      render_change(lv, "task_draft_change", %{"task_auto_complete" => "true"})
      render_click(lv, "task_assign_submit")

      assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
      assert task.auto_complete_on_publish == true
    end

    # A pushed payload is client-chosen (#764), and an unrecognised value must
    # land on "inherit" rather than silently pinning the task either way.
    test "an unrecognised value reads as inherit", %{conn: conn} do
      editor = authed_user(:editor)
      assignee = authed_user(:editor)
      page = page!(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

      render_click(lv, "task_assign_open")
      render_change(lv, "task_draft_change", %{"task_assignee_id" => assignee.id})
      render_change(lv, "task_draft_change", %{"task_auto_complete" => "banana"})
      render_click(lv, "task_assign_submit")

      assert [task] = CMS.list_tasks_for!("page", page.id, actor: editor)
      assert is_nil(task.auto_complete_on_publish)
    end
  end
end
