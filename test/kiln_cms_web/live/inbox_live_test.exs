defmodule KilnCMSWeb.InboxLiveTest do
  @moduledoc """
  `/editor/inbox` (#1320): what an editor sees, what they can mark, where each
  row links to, and — the one that matters — that the page cannot show another
  editor's notifications even though both are editors on the same site.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications

  @password "password123456"

  defp authed_user(name) do
    email = "inboxlive-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor,
      name: name
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
    {org_id, attrs} = Map.pop(attrs, :org_id)

    {:ok, notification} =
      Notifications.record_notification(
        Map.merge(
          %{
            user_id: user.id,
            event: :comment_added,
            content_type: "page",
            content_id: Ecto.UUID.generate(),
            title: "The intro",
            actor_name: "Grace"
          },
          attrs
        ),
        tenant: org_id
      )

    notification
  end

  test "the inbox lists the signed-in editor's notifications", %{conn: conn} do
    me = authed_user("Ada")
    notify(me)

    {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

    assert html =~ "Grace commented"
    assert html =~ "The intro"
  end

  # The row-level guarantee is pinned at the resource
  # (`KilnCMS.Notifications.NotificationTest`, where breaking the read policy
  # kills four tests). What this pins is that the *page* does not widen it:
  # two layers hold it here — the read action's own `user_id` filter and the
  # self-only policy behind it — and this test would still pass if only one
  # survived, so read it as "the inbox shows me mine", not as the policy check.
  test "it does NOT list another editor's, on the same site", %{conn: conn} do
    me = authed_user("Ada")
    colleague = authed_user("Grace")

    notify(colleague, %{title: "Not mine to read"})

    {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

    refute html =~ "Not mine to read"
    assert html =~ "Nothing yet"
  end

  test "an empty inbox says so rather than rendering an empty list", %{conn: conn} do
    me = authed_user("Ada")

    {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

    assert html =~ "Nothing yet"
  end

  describe "marking read" do
    test "one row toggles between read and unread", %{conn: conn} do
      me = authed_user("Ada")
      notification = notify(me)

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      assert render(lv) =~ "Mark read"

      html = lv |> element("button[phx-value-id='#{notification.id}']") |> render_click()
      assert html =~ "Mark unread"

      assert [read] = Notifications.notifications_for_user!(me.id, actor: me)
      assert read.read_at

      html = lv |> element("button[phx-value-id='#{notification.id}']") |> render_click()
      assert html =~ "Mark read"

      assert [unread] = Notifications.notifications_for_user!(me.id, actor: me)
      assert is_nil(unread.read_at)
    end

    test "mark-all-read clears the count and reports how many moved", %{conn: conn} do
      me = authed_user("Ada")
      notify(me)
      notify(me, %{title: "Another"})

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      # Scoped to `#main`: the top bar's bell has a "Mark all read" of its own
      # (#1320), so a bare `button` selector matches two.
      html = lv |> element("#main button", "Mark all read") |> render_click()

      assert html =~ "Marked 2 notifications read"
      assert Notifications.unread_count(me, nil) == 0
      # The button goes away with the count it acted on.
      refute has_element?(lv, "#main button", "Mark all read")
    end

    test "marking a colleague's notification by id does nothing", %{conn: conn} do
      me = authed_user("Ada")
      colleague = authed_user("Grace")
      theirs = notify(colleague)

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      # The id never appears on my page, so this is a hand-crafted push — the
      # shape a client can always send. Two policies stand behind it: the read
      # that looks the row up, and the update that would write it. Mutating
      # *both* to `authorize_if always()` is what makes this test fail, which
      # is the right answer — the page adds no guard of its own and must not
      # need to.
      render_hook(lv, "mark-read", %{"id" => theirs.id})

      assert [still_unread] =
               Notifications.notifications_for_user!(colleague.id, actor: colleague)

      assert is_nil(still_unread.read_at)
    end

    test "a malformed push is a no-op rather than a crash", %{conn: conn} do
      me = authed_user("Ada")
      notify(me)

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      # `%{"id" => true}` misses every guarded clause (#764).
      render_hook(lv, "mark-read", %{"id" => true})
      render_hook(lv, "invented-event", %{})

      assert render(lv) =~ "Grace commented"
    end
  end

  describe "the unread filter" do
    test "it narrows to outstanding items and carries the count", %{conn: conn} do
      me = authed_user("Ada")
      read_one = notify(me, %{title: "Already seen"})
      notify(me, %{title: "Still waiting"})

      {:ok, _marked} = Notifications.mark_notification_read(read_one, actor: me)

      {:ok, lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      assert html =~ "Already seen"
      assert html =~ "Unread (1)"

      unread = lv |> element("#main a", "Unread (1)") |> render_click()

      assert unread =~ "Still waiting"
      # `main/1` again: the bell's dropdown lists read items too, on purpose,
      # so the whole-page HTML legitimately still mentions "Already seen".
      refute main(unread) =~ "Already seen"
    end

    test "an empty unread filter says so differently from an empty inbox", %{conn: conn} do
      me = authed_user("Ada")

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox?filter=unread")

      assert html =~ "Nothing unread."
    end

    test "an unknown filter value falls back to all rather than 500ing", %{conn: conn} do
      me = authed_user("Ada")
      notify(me)

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox?filter=nonsense")

      assert html =~ "Grace commented"
    end
  end

  describe "deep links" do
    test "a block-anchored row links to the thread, not just the document", %{conn: conn} do
      me = authed_user("Ada")
      block_id = Ecto.UUID.generate()
      notification = notify(me, %{block_id: block_id, content_type: "post"})

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      assert html =~ "/editor/posts/#{notification.content_id}?comment=#{block_id}"
    end

    test "a document-level row links to the document", %{conn: conn} do
      me = authed_user("Ada")
      notification = notify(me, %{event: :published, actor_name: nil})

      {:ok, _lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")

      assert html =~ "/editor/pages/#{notification.content_id}"
      # Scheduled publishing has no acting user, so no name is invented.
      assert html =~ "Published"
    end
  end

  describe "live updates" do
    test "a notification recorded elsewhere appears without a reload", %{conn: conn} do
      me = authed_user("Ada")

      {:ok, lv, html} = conn |> log_in(me) |> live(~p"/editor/inbox")
      assert html =~ "Nothing yet"

      # The production write path, which broadcasts on the recipient's topic.
      # `KilnCMSWeb.LiveNotifications`' hook turns that into a reload of this
      # page's `notifications_changed/1`.
      :ok =
        Notifications.record_in_app(%{
          user_id: me.id,
          org_id: nil,
          event: :comment_mention,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "Landed while watching",
          actor_name: "Grace"
        })

      assert render(lv) =~ "Landed while watching"
      assert render(lv) =~ "Grace mentioned you"
    end
  end

  describe "the hook does not break pages that do not show notifications" do
    # `attach_hook` handlers run before the LiveView's own `handle_info/2`, and
    # most console pages have no catch-all clause. If the hook ever stopped
    # halting, this is the test that would catch it — a notification arriving
    # while an editor is on any other console page must not kill the view.
    test "a notification arriving on /editor/tasks leaves it alive", %{conn: conn} do
      me = authed_user("Ada")

      {:ok, lv, _html} = conn |> log_in(me) |> live(~p"/editor/tasks")

      :ok =
        Notifications.record_in_app(%{
          user_id: me.id,
          org_id: nil,
          event: :task_assigned,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "Something to do"
        })

      assert render(lv) =~ "Tasks"
    end
  end

  # The console shell carries a notification bell whose dropdown renders
  # content titles and `?comment=` deep links of its own (#1320), so a
  # whole-page substring assertion can no longer tell this page's list apart
  # from the chrome around it. `main/1` narrows to `<main id="main">`, which is
  # the page's own body — the assertion means what it says again.
  defp main(html) do
    html |> Floki.parse_document!() |> Floki.find("#main") |> Floki.raw_html()
  end
end
