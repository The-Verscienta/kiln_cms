defmodule KilnCMSWeb.BackupReportLiveTest do
  @moduledoc """
  The console side of the backup reports (#2229): the "Backup emails"
  choice in Your settings, a platform admin's alone, and the Backups page
  reading its bell notices, whichever console it is opened on.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications

  @password "password123456"

  defp authed_user(role) do
    email = "backup-report-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
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

  defp reload(user), do: Accounts.get_user!(user.id, authorize?: false)

  describe "Backup emails in Your settings" do
    test "a platform admin sees it, on Failures only, and can choose Every run", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> main_host_conn() |> log_in(admin) |> live(~p"/editor/settings")

      assert has_element?(lv, "#notify-on-backup", "Backup emails")
      assert has_element?(lv, "#notify-on-backup-failures[checked]")
      assert has_element?(lv, "#notify-on-backup", "still appear in your notifications")

      lv
      |> form("#notification-prefs-form", user: %{"notify_on_backup" => "every_run"})
      |> render_submit()

      assert reload(admin).notify_on_backup == :every_run
      assert has_element?(lv, "#notify-on-backup-every_run[checked]")
    end

    test "is hidden from anyone who is not a platform admin, and their form never sets it",
         %{conn: conn} do
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> main_host_conn() |> log_in(editor) |> live(~p"/editor/settings")

      refute has_element?(lv, "#notify-on-backup")

      render_submit(lv, "save", %{"user" => %{"notify_on_backup" => "every_run"}})
      assert reload(editor).notify_on_backup == :failures
    end
  end

  describe "the Backups page" do
    defp backup_row(user, event) do
      org_id = Accounts.default_org_id()

      Notifications.record_in_app_refreshing(%{
        org_id: org_id,
        user_id: user.id,
        event: event,
        content_type: Notifications.platform_backups_content_type(),
        content_id: org_id,
        title: "Kiln",
        excerpt: "20261127-030000 (manual) pg_dump exited 1",
        details: %{"run_id" => Ash.UUID.generate()}
      })
    end

    defp unread(user), do: Notifications.unread_count(user, Accounts.default_org_id())

    test "reads both backup notices, on the default org, from another site's console", %{
      conn: conn
    } do
      admin = authed_user(:admin)
      backup_row(admin, :backup_failed)
      backup_row(admin, :backup_partly_offsite)
      assert unread(admin) == 2

      site =
        Ash.Seed.seed!(Accounts.Organization, %{
          name: "Elsewhere",
          slug: "backup-report-#{System.unique_integer([:positive])}",
          status: :active
        })

      {:ok, _lv, _html} = conn |> org_conn(site) |> log_in(admin) |> live(~p"/editor/backups")

      assert unread(admin) == 0
    end

    test "leaves another platform admin's notices alone", %{conn: conn} do
      admin = authed_user(:admin)
      other = authed_user(:admin)
      backup_row(other, :backup_failed)

      {:ok, _lv, _html} = conn |> log_in(admin) |> live(~p"/editor/backups")

      assert unread(other) == 1
    end
  end
end
