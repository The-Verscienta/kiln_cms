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

    test "is forbidden for non-admins", %{subject: subject} do
      editor = user(:editor)
      assert {:error, %Ash.Error.Forbidden{}} = Accounts.anonymize_user(subject, actor: editor)
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
      # No secrets leak into the export.
      refute Map.has_key?(export.account, :hashed_password)
    end
  end
end
