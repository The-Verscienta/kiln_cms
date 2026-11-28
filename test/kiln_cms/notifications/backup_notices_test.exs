defmodule KilnCMS.Notifications.BackupNoticesTest do
  @moduledoc """
  The notification side of the backup reports (#2229): who is mailed for
  which class (`backup_mail?/2`), the backup rows in the platform alert
  count another console shows, and their link and headline.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Link
  alias KilnCMS.Types.UnknownAtom
  alias KilnCMSWeb.NotificationText

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "backup-notice-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp backup_row(user, event \\ :backup_failed) do
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

  defp site do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Other Site",
      slug: "backup-notices-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  describe "backup_mail?/2" do
    test ":failures covers failed and partial runs only" do
      user = %{notify_on_backup: :failures, anonymized_at: nil}
      assert Notifications.backup_mail?(user, :failed)
      assert Notifications.backup_mail?(user, :partial)
      refute Notifications.backup_mail?(user, :succeeded)
      refute Notifications.backup_mail?(user, :skipped)
      refute Notifications.backup_mail?(user, :canceled)
    end

    test ":every_run covers all, :off none" do
      for class <- KilnCMS.Backups.Report.classes() do
        assert Notifications.backup_mail?(
                 %{notify_on_backup: :every_run, anonymized_at: nil},
                 class
               )

        refute Notifications.backup_mail?(%{notify_on_backup: :off, anonymized_at: nil}, class)
      end
    end

    test "a value this release doesn't know is :failures" do
      user = %{notify_on_backup: %UnknownAtom{value: "weekly"}, anonymized_at: nil}
      assert Notifications.backup_mail?(user, :failed)
      refute Notifications.backup_mail?(user, :succeeded)
    end

    test "an erased account gets none" do
      user = %{notify_on_backup: :every_run, anonymized_at: DateTime.utc_now()}
      refute Notifications.backup_mail?(user, :failed)
    end
  end

  describe "the platform alert count on another site's console" do
    test "counts unread backup rows for a platform admin" do
      admin = user(:admin)
      assert :recorded = backup_row(admin)
      assert :recorded = backup_row(admin, :backup_partly_offsite)

      assert Notifications.unread_platform_alert_count(admin, site()) == 2
      # The default console lists the rows itself.
      assert Notifications.unread_platform_alert_count(admin, Accounts.default_org_id()) == 0
    end

    test "is 0 for someone who is not a platform admin" do
      editor = user(:editor)
      backup_row(editor)
      assert Notifications.unread_platform_alert_count(editor, site()) == 0
    end
  end

  describe "a collapsing row" do
    test "is refreshed while unread, not written twice" do
      admin = user(:admin)
      assert :recorded = backup_row(admin)
      assert :refreshed = backup_row(admin)
      assert Notifications.unread_count(admin, Accounts.default_org_id()) == 1
    end
  end

  describe "link and headline" do
    test "both events link to the Backups page and have their own headline" do
      for event <- [:backup_failed, :backup_partly_offsite] do
        subject = %{
          event: event,
          content_type: "platform_backups",
          content_id: Ash.UUID.generate()
        }

        assert Link.editor_path(subject) == "/editor/backups"
        assert Link.editor_url(subject) =~ ~r{^https?://[^/]+/editor/backups$}
      end

      assert NotificationText.headline(%{event: :backup_failed}) == "A backup failed"

      assert NotificationText.headline(%{event: :backup_partly_offsite}) ==
               "A backup reached only some destinations"
    end
  end
end
