defmodule KilnCMSWeb.NavBadgeTest do
  @moduledoc """
  The open-task count beside "Tasks" in the console sidebar
  (`KilnCMSWeb.NavBadge`): what it counts, that it stays live, and that an
  ordinary re-render does not re-count.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"
  @badge "#nav-badge-tasks"

  defp authed_user(role) do
    email = "navbadge-#{System.unique_integer([:positive])}@example.com"

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
    slug = "navbadge-#{System.unique_integer([:positive])}"
    CMS.create_page!(%{title: "Page #{slug}", slug: slug}, actor: actor)
  end

  defp assign!(assignee, actor) do
    CMS.assign_task!(
      %{content_type: "page", content_id: page!(actor).id, assignee_id: assignee.id},
      actor: actor
    )
  end

  # Shown means present and not `hidden`; the pill text and the sentence a
  # screen reader hears both carry the number.
  defp shown_count(lv) do
    if has_element?(lv, "#{@badge}:not([hidden])") do
      lv |> element("#{@badge} .side-badge") |> render() |> text()
    end
  end

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()

  test "the Tasks link carries the viewer's open-task count", %{conn: conn} do
    editor = authed_user(:editor)
    assign!(editor, editor)
    assign!(editor, editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    assert shown_count(lv) == "2"
    # Inside the link, so it is part of the link's name: "Tasks (2 open)".
    assert has_element?(lv, ~s(a[href="/editor/tasks"] #{@badge} .sr-only), "(2 open)")
  end

  test "no open tasks, no badge", %{conn: conn} do
    editor = authed_user(:editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    assert has_element?(lv, "#{@badge}[hidden]")
    assert shown_count(lv) == nil
  end

  test "only the viewer's own OPEN tasks count", %{conn: conn} do
    editor = authed_user(:editor)
    other = authed_user(:editor)

    assign!(editor, editor)
    assign!(other, editor)
    done = assign!(editor, editor)
    CMS.complete_task!(done, %{}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    assert shown_count(lv) == "1"
  end

  # The real path, not a stubbed message: assigning notifies the assignee, the
  # notification reaches their open console over PubSub, and
  # `LiveNotifications` asks the badge to re-count.
  test "a task assigned while the page is open appears without navigating", %{conn: conn} do
    editor = authed_user(:editor)
    colleague = authed_user(:editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")
    assert shown_count(lv) == nil

    assign!(editor, colleague)

    # `send_update/2` queues behind the render that triggers it: the first
    # render drains the PubSub message, the second shows the update.
    _ = render(lv)
    assert shown_count(lv) == "1"
  end

  test "completing a task on the Tasks screen lowers the count at once", %{conn: conn} do
    editor = authed_user(:editor)
    task = assign!(editor, editor)
    assign!(editor, editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/tasks")
    assert shown_count(lv) == "2"

    lv |> element(~s(button[phx-click="complete"][phx-value-id="#{task.id}"])) |> render_click()

    _ = render(lv)
    assert shown_count(lv) == "1"
  end

  # The reason it is a LiveComponent that checks its scope: a re-render that
  # reaches it must not re-count, or every sidebar redraw is a query. Switching
  # the sidebar preset is such a redraw — `NavPreset` swaps in a new
  # `current_user` (same id) and the nav re-renders in place, calling the
  # badge's `update/2`. A task that lands with no notification (seeded, so
  # nothing is announced) must therefore NOT show then — only on a refresh.
  #
  # A plain `render_patch` would not do: change tracking never reaches the
  # badge when nothing it depends on changed, so it cannot tell a scope check
  # from its absence.
  test "a sidebar redraw does not re-count; a refresh does", %{conn: conn} do
    editor = authed_user(:editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/tasks")
    assert shown_count(lv) == nil

    Ash.Seed.seed!(
      KilnCMS.CMS.Task,
      %{
        content_type: "page",
        content_id: page!(editor).id,
        assignee_id: editor.id,
        status: :open,
        kind: :manual
      },
      tenant: KilnCMS.Accounts.default_org_id()
    )

    lv |> element("#nav-preset-switch") |> render_click()
    _ = render(lv)
    assert shown_count(lv) == nil

    send(lv.pid, :notifications_changed)
    _ = render(lv)
    assert shown_count(lv) == "1"
  end
end
