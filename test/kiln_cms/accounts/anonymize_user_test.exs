defmodule KilnCMS.Accounts.AnonymizeUserTest do
  @moduledoc """
  Admin erasure (#212) scrubs PII from a user while retaining audit history:
  the row is tombstoned, stored tokens are revoked, and the actor on the user's
  block-level events is nulled (#219). Self-service export returns the account's
  own data (Art. 15/20).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Token, User}
  alias KilnCMS.History.DocumentEvent

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp token_for(user) do
    Ash.Seed.seed!(Token, %{
      jti: "jti-#{System.unique_integer([:positive])}",
      subject: AshAuthentication.user_to_subject(user),
      purpose: "user",
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
    })
  end

  defp event_by(user) do
    Ash.Seed.seed!(DocumentEvent, %{
      document_type: :page,
      document_id: Ash.UUID.generate(),
      seq: 1,
      kind: :snapshot,
      payload: %{"blocks" => []},
      actor_id: user.id
    })
  end

  describe "anonymize" do
    setup do
      %{admin: user(:admin), subject: user(:editor, %{name: "Jane Editor"})}
    end

    test "scrubs PII while keeping the row", %{admin: admin, subject: subject} do
      assert {:ok, anon} = Accounts.anonymize_user(subject, actor: admin)

      assert to_string(anon.email) == "anonymized-#{subject.id}@deleted.invalid"
      assert is_nil(anon.name)
      assert anon.role == :viewer
      assert anon.anonymized_at
      # Same row — erasure preserves authorship links / referential integrity.
      assert anon.id == subject.id
    end

    test "restores every notification preference to its default", %{admin: admin} do
      muted =
        user(:admin, %{
          notify_on_review_request: false,
          notify_on_publish: false,
          notify_on_return_to_draft: false,
          notify_on_comment: false,
          notify_on_registration: false
        })

      assert {:ok, anon} = Accounts.anonymize_user(muted, actor: admin)

      assert anon.notify_on_review_request
      assert anon.notify_on_publish
      assert anon.notify_on_return_to_draft
      assert anon.notify_on_comment
      assert anon.notify_on_registration
    end

    test "scrambles the password so the account can't sign in", %{admin: admin, subject: subject} do
      original = Ash.get!(User, subject.id, authorize?: false).hashed_password
      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)
      reloaded = Ash.get!(User, subject.id, authorize?: false).hashed_password

      assert reloaded != original
    end

    test "revokes the user's stored tokens", %{admin: admin, subject: subject} do
      token = token_for(subject)

      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      revoked = Ash.get!(Token, token.jti, authorize?: false)
      assert revoked.purpose == "revocation"
    end

    test "nulls the actor on the user's audit events", %{admin: admin, subject: subject} do
      event = event_by(subject)

      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      reloaded = Ash.get!(DocumentEvent, event.id, authorize?: false)
      assert is_nil(reloaded.actor_id)
    end

    test "blanks their name in other people's in-app notifications", %{
      admin: admin,
      subject: subject
    } do
      recipient = user(:editor)

      :ok =
        KilnCMS.Notifications.record_in_app(%{
          user_id: recipient.id,
          org_id: nil,
          event: :comment_mention,
          content_type: "page",
          content_id: Ash.UUID.generate(),
          title: "A draft",
          actor_id: subject.id,
          actor_name: "Jane Editor"
        })

      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      assert [row] = KilnCMS.Notifications.notifications_for_user!(recipient.id, actor: recipient)
      assert is_nil(row.actor_name)
    end

    test "is forbidden for non-admins", %{subject: subject} do
      editor = user(:editor)
      assert {:error, %Ash.Error.Forbidden{}} = Accounts.anonymize_user(subject, actor: editor)
    end
  end

  describe "the security audit log (#2241)" do
    alias KilnCMS.NewerReleaseRows
    alias KilnCMS.Security
    alias KilnCMS.Security.Event

    defp events do
      Event
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())
    end

    defp record!(attrs) do
      Security.record!(attrs,
        actor: Security.system(),
        tenant: KilnCMS.Accounts.default_org_id()
      )
    end

    test "erasing a user scrubs their events, as actor and as target, and keeps the events" do
      admin = user(:admin)
      subject = user(:editor)

      acted =
        record!(%{
          type: :sign_in,
          actor_id: subject.id,
          actor_label: "x@example.com",
          ip: "192.0.2.7"
        })

      targeted =
        record!(%{
          type: :role_granted,
          actor_id: admin.id,
          target_type: "user",
          target_id: subject.id,
          ip: "192.0.2.8"
        })

      assert {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      rows = Map.new(events(), &{&1.id, &1})
      assert map_size(rows) == 2

      a = rows[acted.id]
      assert {a.actor_id, a.actor_label, a.ip} == {nil, nil, nil}

      t = rows[targeted.id]
      assert t.target_id == nil
      # The admin who acted keeps their own identity on the event.
      assert t.actor_id == admin.id and t.ip == "192.0.2.8"
    end

    # Rows a newer release wrote, with a type or event this release does not
    # know (#2509): erasure must still reach them, not fail on reading them.
    test "erasure completes over a security event and notifications a newer release wrote" do
      admin = user(:admin)
      subject = user(:editor)
      recipient = user(:editor)

      acted =
        NewerReleaseRows.security_event!(%{
          actor_id: subject.id,
          actor_label: "x@example.com",
          ip: "192.0.2.7",
          user_agent: "UA",
          metadata: %{"name" => "laptop"}
        })

      caused =
        NewerReleaseRows.notification!(recipient.id, %{
          actor_id: subject.id,
          actor_name: "Jane Editor"
        })

      received = NewerReleaseRows.notification!(subject.id)

      assert {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      a = NewerReleaseRows.stored_row("security_events", acted)

      assert {a["actor_id"], a["actor_label"], a["ip"], a["user_agent"], a["metadata"]} ==
               {nil, nil, nil, nil, %{}}

      assert a["type"] == NewerReleaseRows.unknown()

      c = NewerReleaseRows.stored_row("notifications", caused)

      assert {c["actor_id"], c["actor_name"], c["event"]} ==
               {nil, nil, NewerReleaseRows.unknown()}

      assert %{num_rows: 0} =
               KilnCMS.Repo.query!("SELECT 1 FROM notifications WHERE id = $1", [
                 Ecto.UUID.dump!(received)
               ])
    end

    test "a failed security-log scrub fails and rolls back the erasure" do
      admin = user(:admin)
      subject = user(:editor)
      acted = record!(%{type: :sign_in, actor_id: subject.id, ip: "192.0.2.7"})

      # The scrub raises inside the erasure's transaction, so the whole erasure
      # comes back an error and rolls back: no tombstone with a live audit trail.
      assert {:error, _} =
               Security.with_actor(nil, fn -> Accounts.anonymize_user(subject, actor: admin) end)

      assert is_nil(Ash.get!(User, subject.id, authorize?: false).anonymized_at)

      assert [%{id: id, actor_id: actor_id}] = events()
      assert id == acted.id and actor_id == subject.id
    end
  end

  describe "export_user_data/1" do
    test "returns the account's own profile and notification preferences" do
      u = user(:editor, %{name: "Export Me", notify_on_publish: false})

      export = Accounts.export_user_data(u)

      assert export.account.id == u.id
      assert export.account.name == "Export Me"
      assert export.account.role == :editor
      assert export.notification_preferences.notify_on_publish == false
      assert export.notification_preferences.notify_on_comment == true
      assert export.notification_preferences.notify_on_registration == true

      muted = user(:admin, %{notify_on_comment: false, notify_on_registration: false})
      prefs = Accounts.export_user_data(muted).notification_preferences
      assert prefs.notify_on_comment == false
      assert prefs.notify_on_registration == false
      # No secrets leak into the export.
      refute Map.has_key?(export.account, :hashed_password)
    end
  end
end
