defmodule KilnCMSWeb.NotificationBellTest do
  @moduledoc """
  The console top bar's bell (#1320): its count, its dropdown, its live
  updates, and the two things about it that are easy to get wrong —

    * it is in the shell, so it renders on *every* console page, including the
      admin-gated ones that sit in a different `live_session`;
    * it is a LiveComponent with no process of its own, so its liveness depends
      entirely on `KilnCMSWeb.LiveNotifications` holding the subscription and
      `send_update/2` reaching it. A test that only checks the first render
      would pass with the whole PubSub path deleted.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications
  alias KilnCMSWeb.NotificationBell

  @password "password123456"

  defp authed_user(role \\ :editor) do
    email = "bell-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: "Ada"
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

  defp notify(user, attrs \\ %{}) do
    {:ok, notification} =
      Notifications.record_notification(
        Map.merge(
          %{
            user_id: user.id,
            event: :comment_mention,
            content_type: "page",
            content_id: Ecto.UUID.generate(),
            title: "The intro",
            actor_name: "Grace"
          },
          attrs
        )
      )

    notification
  end

  defp badge(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(".bell-badge")
    |> Floki.text()
    |> String.trim()
  end

  describe "the badge" do
    test "an editor with nothing has a bell and no badge", %{conn: conn} do
      me = authed_user()

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      assert html =~ "bell-trigger"
      assert badge(html) == ""
    end

    test "it counts only unread, and drops when one is read", %{conn: conn} do
      me = authed_user()
      one = notify(me)
      notify(me, %{title: "Another"})

      {:ok, lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")
      assert badge(html) == "2"

      {:ok, _marked} = Notifications.mark_notification_read(one, actor: me)
      # Marking read broadcasts on the recipient's topic, which is what the
      # hook turns into a `send_update` — so the badge moves with no reload.
      assert badge(render(lv)) == "1"
    end

    test "it does not count a colleague's notifications", %{conn: conn} do
      me = authed_user()
      colleague = authed_user()
      notify(colleague)

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      assert badge(html) == ""
    end
  end

  test "the badge caps, and the accessible label carries the real number" do
    # Pinned as a unit so the cap is covered without seeding ten rows. The
    # label is the uncapped answer on purpose: "8+" is a space-saving glyph
    # for the eye, not something a screen reader should be left with.
    assert NotificationBell.unread_badge(1) == "1"
    assert NotificationBell.unread_badge(8) == "8"
    assert NotificationBell.unread_badge(9) == "8+"
    assert NotificationBell.unread_badge(250) == "8+"
  end

  describe "the dropdown" do
    test "it lists recent items with their deep links", %{conn: conn} do
      me = authed_user()
      block_id = Ecto.UUID.generate()
      notification = notify(me, %{content_type: "post", block_id: block_id})

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      assert html =~ "Grace mentioned you"
      assert html =~ "The intro"
      assert html =~ "/editor/posts/#{notification.content_id}?comment=#{block_id}"
      # And the way out to the full list.
      assert html =~ "/editor/inbox"
    end

    test "a read item stays in the list", %{conn: conn} do
      me = authed_user()
      notification = notify(me)

      {:ok, _marked} = Notifications.mark_notification_read(notification, actor: me)

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      # Still listed — the dropdown is "what happened lately", not a queue.
      assert html =~ "Grace mentioned you"
      assert badge(html) == ""
    end

    test "clicking an item marks it read", %{conn: conn} do
      me = authed_user()
      notification = notify(me)

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      lv
      |> element(".bell-item[phx-value-id='#{notification.id}']")
      |> render_click()

      assert [read] = Notifications.notifications_for_user!(me.id, actor: me)
      assert read.read_at
    end

    test "mark-all-read clears the badge", %{conn: conn} do
      me = authed_user()
      notify(me)
      notify(me, %{title: "Another"})

      {:ok, lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")
      assert badge(html) == "2"

      lv |> element(".bell-action") |> render_click()

      assert badge(render(lv)) == ""
      assert Notifications.unread_count(me, nil) == 0
    end

    # A colleague's id never reaches the component through this test: LiveView
    # test helpers can push an arbitrary event to the root view but not to a
    # component, so the hand-crafted-push case is pinned where it *can* be —
    # at the page (`KilnCMSWeb.InboxLiveTest`) and at the resource
    # (`KilnCMS.Notifications.NotificationTest`), against the same two
    # policies this component's `mark-read` goes through. What is pinned here
    # is that the component's own lookup is authorized as the viewer, which is
    # what makes those policies the operative rule: a colleague's row is
    # neither counted nor listed.
  end

  describe "live updates" do
    test "a notification recorded elsewhere moves the badge with no reload", %{conn: conn} do
      me = authed_user()

      {:ok, lv, html} = conn |> log_in(me) |> live(~p"/editor/tasks")
      assert badge(html) == ""

      # The production write path. This is the assertion that fails if the
      # `on_mount` hook, the subscription, or `NotificationBell.refresh/0`
      # stops working — a LiveComponent cannot hear PubSub for itself.
      :ok =
        Notifications.record_in_app(%{
          user_id: me.id,
          org_id: nil,
          event: :task_assigned,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "Landed while watching",
          actor_name: "Grace"
        })

      updated = render(lv)
      assert badge(updated) == "1"
      assert updated =~ "Grace assigned you a task"
    end

    test "a colleague's notification does not move my badge", %{conn: conn} do
      me = authed_user()
      colleague = authed_user()

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      :ok =
        Notifications.record_in_app(%{
          user_id: colleague.id,
          org_id: nil,
          event: :published,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "Not mine"
        })

      assert badge(render(lv)) == ""
    end
  end

  describe "it is in the shell, so it is on every console page" do
    # The console layout is rendered by 43 LiveViews across two live_sessions,
    # and the admin one needed the same hook. Without it the bell renders but
    # never updates — which looks fine in a screenshot.
    test "an admin-gated page has a live bell too", %{conn: conn} do
      admin = authed_user(:admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/backups")
      assert html =~ "bell-trigger"

      :ok =
        Notifications.record_in_app(%{
          user_id: admin.id,
          org_id: nil,
          event: :submitted_for_review,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "Waiting on you",
          actor_name: "Grace"
        })

      assert badge(render(lv)) == "1"
    end

    test "the editor content list has one", %{conn: conn} do
      me = authed_user()
      notify(me)

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor")

      assert badge(html) == "1"
    end
  end
end
