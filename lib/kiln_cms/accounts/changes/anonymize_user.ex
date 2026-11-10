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

  It also deletes what belongs to the account alone and names or reaches the
  person (#2514): its Web Push subscriptions (a device endpoint), its private
  saved views (shared ones are the team's, kept like authored content), and
  the notifications addressed to it.
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
      # Consumer read entitlements are cleared too (#337 Phase 2). This was a
      # pre-existing gap: an erased account kept whatever audiences it held, so
      # its credentials were destroyed while its ACCESS survived. Now that a paid
      # membership can grant an audience, leaving them would also mean a
      # tombstoned account still reading paywalled content.
      audiences: [],
      notify_on_review_request: true,
      notify_on_publish: true,
      notify_on_return_to_draft: true,
      notify_on_comment: true,
      notify_on_registration: true,
      notify_on_security_alert: true,
      anonymized_at: DateTime.utc_now()
    })
    |> Ash.Changeset.after_action(fn _changeset, user ->
      revoke_tokens(user)
      remove_identities(user)
      remove_passkeys(user)
      revoke_api_keys(user)
      clear_audiences(user)
      clear_account_grant(user)
      clear_membership_grants(user)
      cancel_memberships(user)
      remove_push_subscriptions(user)
      remove_private_saved_views(user)
      :ok = KilnCMS.Notifications.forget_recipient(user.id)
      :ok = History.anonymize_actor(user.id)
      :ok = KilnCMS.Billing.anonymize_actor(user.id)
      # Their name, snapshotted into other people's inboxes (#1320).
      :ok = KilnCMS.Notifications.anonymize_actor(user.id)
      # Security audit log (#2241): events they acted in or were the target of.
      :ok = KilnCMS.Security.anonymize_actor(user.id)
      {:ok, user}
    end)
  end

  # Locally cancel every paid membership and drop the provider identifiers
  # (#337 Phase 2). Without this a later reconcile or a late webhook would
  # recompute entitlements and re-grant audiences to a tombstoned account.
  #
  # **Local only — this does NOT cancel the subscription at the payment
  # provider.** Two reasons, and the trade-off is documented in
  # `docs/data-flows.md` so an operator knows to do it themselves:
  #
  #   * erasure runs inside this update's transaction, and an outbound call to a
  #     third party does not belong there — a provider outage must not block a
  #     data-subject request;
  #   * `KilnCMS.Staging.Scrub` calls this action over a *clone* of production. A
  #     scrub that cancelled subscriptions would cancel REAL customers' billing
  #     from a staging environment.
  #
  # Cross-org by necessity: the person may hold memberships on several sites, and
  # each write is re-scoped to its own row's `org_id`.
  defp cancel_memberships(user) do
    # authorize?: false — erasure is already authorized as `:anonymize`, and no
    # actor may read another person's memberships across every org.
    case KilnCMS.Billing.memberships_for_export(user.id, authorize?: false) do
      {:ok, memberships} ->
        Enum.each(memberships, &KilnCMS.Billing.anonymize_membership(&1))

      _error ->
        :ok
    end
  end

  # Revoke every live API key. A key is a whole credential — `:sign_in_with_api_key`
  # signs its owner in with no password — so an erased account whose keys survive
  # can still authenticate, which the token revocation above does nothing about.
  # `:revoke` (not a delete) keeps the audit row, as the rest of erasure does.
  defp revoke_api_keys(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id.
    KilnCMS.Accounts.ApiKey
    |> Ash.Query.filter(user_id == ^user.id and is_nil(revoked_at))
    |> Ash.bulk_update!(:revoke, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Clear the account's audiences in SQL, for the reason `clear_account_grant/1`
  # gives below: the forced `audiences: []` above is dropped whenever the caller's
  # struct already reads `[]` (one read before a billing recompute granted
  # some), and the column keeps them. A later recompute used to wipe them as a
  # side effect; since #2514 a recompute writes nothing to an erased account.
  defp clear_audiences(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub); `:sync_billing_audiences` refuses any
    # actor-carrying call by design, and the filter pins the write to this
    # user's id.
    KilnCMS.Accounts.User
    |> Ash.Query.filter(id == ^user.id and fragment("coalesce(cardinality(?), 0) > 0", audiences))
    |> Ash.bulk_update!(:sync_billing_audiences, %{audiences: []},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Clear the account's own temporary grant. `role: :viewer` alone did nothing
  # while a grant was live — the effective tier stayed the granted one, which put
  # `anonymized-…@deleted.invalid` on the admin roster and
  # in the assignee picker until the grant ran out: the gap `audiences` had above,
  # on the axis that grants the most.
  #
  # A bulk write filtered in SQL rather than `force_change_attributes` above: Ash
  # drops a forced change equal to `changeset.data`, and a caller holding a struct
  # read before the grant existed has `granted_role: nil` there — so `nil` → `nil`
  # was "no change" and the column kept its grant.
  defp clear_account_grant(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id.
    KilnCMS.Accounts.User
    |> Ash.Query.filter(id == ^user.id and not is_nil(granted_role))
    |> Ash.bulk_update!(:expire_role_grant, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Clear any temporary per-site tier. Same reasoning as the account's own grant
  # above: the membership row survives erasure (it is the audit of who belonged
  # where), and a live `granted_role` on it would keep the tombstone a site
  # editor or admin until it expired.
  defp clear_membership_grants(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id.
    KilnCMS.Accounts.OrgMembership
    |> Ash.Query.filter(user_id == ^user.id and not is_nil(granted_role))
    |> Ash.bulk_update!(:expire_role_grant, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Delete the account's Web Push subscriptions (#2514): each is a browser's
  # endpoint and keys, a way to reach the person's device, and nothing else
  # needs it once they are gone. One statement: the resource is not
  # tenant-scoped (its `org_id` is the site that minted it, not a tenant).
  defp remove_push_subscriptions(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize`
    # action (or the staging scrub). The person being erased owns these rows,
    # so no admin actor would be admitted to them, and the filter pins every
    # row to this user's id.
    KilnCMS.Accounts.PushSubscription
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Delete the account's private saved views (#2514). A shared view is an
  # admin's published filter the team uses, so it stays, as authored content
  # does; its `owner_id` points at the tombstone, which names nobody.
  #
  # One statement per org: saved views are tenant-scoped under strict tenancy
  # and have no tenant-bypassing action, and adding one only for this would
  # widen the resource. Erasure is rare, so a delete per site is the price
  # (`Notifications.forget_recipient/1` pays it the same way).
  defp remove_private_saved_views(user) do
    require Ash.Query

    each_org(fn org_id ->
      # authorize?: false — erasure is authorized once, as the `:anonymize`
      # action (or the staging scrub). The person being erased owns these rows,
      # so no admin actor would be admitted to them, and the filter pins every
      # row to this user's id.
      KilnCMS.CMS.SavedView
      |> Ash.Query.filter(owner_id == ^user.id and shared == false)
      |> Ash.bulk_destroy!(:destroy, %{},
        tenant: org_id,
        authorize?: false,
        strategy: [:atomic, :atomic_batches, :stream],
        return_records?: false,
        return_errors?: true
      )
    end)
  end

  defp each_org(fun), do: Enum.each(KilnCMS.Accounts.list_org_ids(), fun)

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

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id.
    KilnCMS.Accounts.UserIdentity
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  # Delete the user's WebAuthn credentials (#331 passkeys): a surviving
  # passkey would let the erased account sign straight back in — the same
  # class of live credential as the IdP links above.
  defp remove_passkeys(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id.
    KilnCMS.Accounts.Passkey
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

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). The person being erased owns these rows, so no
    # admin actor would be admitted to them, and the filter pins every row to
    # this user's id; the private `ash_authentication?` context is what the token
    # resource requires of any revocation.
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
