defmodule KilnCMS.Accounts.Changes.AnonymizeUser do
  @moduledoc """
  Scrubs personal data from a `User` while keeping the row (and the audit/version
  history that references it) intact — the GDPR-erasure path that reconciles with
  audit retention (#212/#219).

  On the account row it: replaces the email with a unique non-routable tombstone,
  clears the display name, scrambles the password hash (so the credentials can
  never sign in again), resets the role to the least-privileged `:viewer`,
  restores default notification preferences, and stamps `anonymized_at`.

  After the row is written it: revokes every stored auth token for the subject
  (logging the account out everywhere and removing token PII via the existing
  AshAuthentication revocation flow), and nulls the `actor_id` on the user's
  block-level events so the audit trail keeps the *what* without the *who*.
  """
  use Ash.Resource.Change

  alias KilnCMS.History

  @impl true
  def change(changeset, _opts, _context) do
    id = Ash.Changeset.get_attribute(changeset, :id)

    changeset
    |> Ash.Changeset.force_change_attributes(%{
      email: "anonymized-#{id}@deleted.invalid",
      name: nil,
      hashed_password: random_hash(),
      role: :viewer,
      notify_on_review_request: true,
      notify_on_publish: true,
      notify_on_return_to_draft: true,
      anonymized_at: DateTime.utc_now()
    })
    |> Ash.Changeset.after_action(fn _changeset, user ->
      revoke_tokens(user)
      remove_identities(user)
      :ok = History.anonymize_actor(user.id)
      {:ok, user}
    end)
  end

  # A throwaway bcrypt hash of random bytes — there is no plaintext that matches
  # it, so the scrubbed account can never authenticate.
  defp random_hash do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Bcrypt.hash_pwd_salt()
  end

  # Delete the user's external-IdP links (#331): a user_identities row carries
  # the provider's stable subject identifier plus live OAuth access/refresh
  # tokens — personal data (and usable credentials) that must not survive
  # erasure, and removing the link also prevents any future SSO sign-in from
  # re-attaching to the tombstoned account.
  defp remove_identities(user) do
    require Ash.Query

    KilnCMS.Accounts.UserIdentity
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Revoke (mark as `revocation`) every stored token for this subject, mirroring
  # AshAuthentication's `log_out_everywhere` add-on.
  defp revoke_tokens(user) do
    subject = AshAuthentication.user_to_subject(user)

    KilnCMS.Accounts.Token
    |> Ash.bulk_update(:revoke_all_stored_for_subject, %{subject: subject},
      authorize?: false,
      context: %{private: %{ash_authentication?: true}},
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )

    :ok
  end
end
