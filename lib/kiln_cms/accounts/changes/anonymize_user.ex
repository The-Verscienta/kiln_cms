defmodule KilnCMS.Accounts.Changes.AnonymizeUser do
  @moduledoc """
  Scrubs personal data from a `User` while keeping the row (and the audit/version
  history that references it) intact — the GDPR-erasure path that reconciles with
  audit retention (#212/#219).

  On the account row it: replaces the email with a unique non-routable tombstone,
  clears the display name, scrambles the password hash (so the credentials can
  never sign in again), resets the role to the least-privileged `:viewer`,
  restores default notification preferences, and stamps `anonymized_at`. It
  also clears two-step verification (#2594): the live secret, the recovery-code
  hashes and any staged re-enrollment. Those columns are read from the row
  under a lock in a `before_action` first, as `Changes.ForgetPriorCredentials`
  reads them, because Ash drops a forced change equal to the caller's struct,
  and a struct read before the factor was enrolled holds `nil` there.

  After the row is written it: revokes every stored auth token for the subject
  (logging the account out everywhere and removing token PII via the existing
  AshAuthentication revocation flow), and nulls the `actor_id` on the user's
  block-level events so the audit trail keeps the *what* without the *who*.

  Its site memberships stay, as the record of who belonged where, but grant
  nothing (#2774): each is demoted to a bare `:viewer` row with no temporary
  tier and no audiences (`OrgMembership.:erase`, see `granting/0`). An erased
  account is also never on a roster and has no tier anywhere
  (`KilnCMS.Accounts.Scoping`), and a membership edit or temporary tier that
  reaches it afterwards is refused (`Changes.LockAccount`).

  The account's row is taken `FOR UPDATE` (`KilnCMS.Accounts.AccountLock`)
  before any other row the erasure writes, so a write that locks the account
  first (`AccountLock`'s path list) either commits before the erasure starts
  or waits for it and sees the tombstone.

  It also deletes what belongs to the account alone and names or reaches the
  person (#2514): its Web Push subscriptions (a device endpoint), its private
  saved views (shared ones are the team's, kept like authored content), and
  the notifications addressed to it. Its newsletter subscriber rows go too
  (#2991, `KilnCMS.Newsletter.forget_member/1`): the ones linked to the
  account, on every site, so the address it was registered with stops
  receiving newsletters. A row added by hand at the same address and never
  linked is not the account's and is kept.

  Account mail still waiting to run is withheld (#3035,
  `KilnCMS.Mail.withhold_pending/2`): it loses its address and message and is
  completed unsent, and a job queued with the old address after this ran is
  caught when it runs (`KilnCMS.Mail.DeliveryWorker` checks the account
  again). Finished jobs on the `mail` queue lose the address they were sent
  to (#3019, `KilnCMS.Mail.forget_recipient/2`), and the address comes off the
  instance-wide suppression list and every site's (#3036,
  `KilnCMS.Mail.forget_suppressions/2`). The address is read from the row
  before the tombstone replaces it. Workflow and task mail still waiting to
  run carry no address and check the recipient again when they run.
  """
  use Ash.Resource.Change

  require Ash.Expr
  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.History

  # The plaintext columns too: a row the backfill has
  # not reached keeps its secrets there.
  @totp_cleared [
    totp_secret: nil,
    legacy_totp_secret: nil,
    totp_confirmed_at: nil,
    totp_pending_secret: nil,
    legacy_totp_pending_secret: nil,
    totp_recovery_hashes: []
  ]

  @impl true
  def change(changeset, _opts, _context) do
    id = Ash.Changeset.get_attribute(changeset, :id)

    changeset
    |> Ash.Changeset.before_action(&lock_account/1)
    |> Ash.Changeset.before_action(&clear_totp/1)
    |> Ash.Changeset.before_action(&remember_address/1)
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
      notify_on_webhook_failure: true,
      anonymized_at: DateTime.utc_now()
    })
    |> Ash.Changeset.after_action(fn changeset, user ->
      revoke_tokens(user)
      remove_identities(user)
      remove_passkeys(user)
      revoke_api_keys(user)
      clear_audiences(user)
      clear_account_grant(user)
      demote_memberships(user)
      cancel_memberships(user)
      # After the cancel above, so a membership transition it triggers cannot
      # re-link a row this deletes (#2991).
      :ok = KilnCMS.Newsletter.forget_member(user.id)
      remove_push_subscriptions(user)
      # Private ones only; shared views are the team's (#2514).
      :ok = KilnCMS.CMS.SavedViews.forget_private_views(user.id, Accounts.list_org_ids())
      :ok = KilnCMS.Notifications.forget_recipient(user.id)
      # Account mail still waiting to run is withheld (#3035), and finished
      # mail jobs lose the address they were sent to (#3019); the address
      # comes off the suppression lists (#3036).
      :ok = forget_mail(changeset, user)
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

  # The TOTP columns, against the row read under a lock rather than the
  # caller's struct (see the moduledoc).
  defp clear_totp(changeset) do
    # authorize?: false — erasure is authorized once, as the `:anonymize`
    # action (or the staging scrub); only the TOTP columns are read, and only
    # to be cleared.
    case Accounts.get_user(changeset.data.id,
           authorize?: false,
           not_found_error?: false,
           query: Ash.Query.lock(User, "FOR NO KEY UPDATE")
         ) do
      {:ok, %User{} = row} ->
        fresh = Map.take(row, Keyword.keys(@totp_cleared))

        %{changeset | data: struct(changeset.data, fresh)}
        |> Ash.Changeset.force_change_attributes(@totp_cleared)

      {:ok, nil} ->
        Ash.Changeset.force_change_attributes(changeset, @totp_cleared)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The address the account holds before the tombstone replaces it, from the
  # row (after `lock_account/1`) rather than the caller's struct, so the
  # finished mail jobs addressed to it can be found once the row is written.
  defp remember_address(changeset) do
    # authorize?: false — erasure is authorized once, as the `:anonymize`
    # action (or the staging scrub); only the address is read, to find the
    # mail jobs that still hold it.
    case Accounts.get_user(changeset.data.id,
           authorize?: false,
           not_found_error?: false,
           query: [select: [:id, :email]]
         ) do
      {:ok, %User{email: email}} when not is_nil(email) ->
        Ash.Changeset.put_context(changeset, :erased_address, to_string(email))

      {:ok, _no_address} ->
        changeset

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp forget_mail(changeset, user) do
    address = changeset.context[:erased_address]
    :ok = KilnCMS.Mail.withhold_pending(address, user.id)
    :ok = KilnCMS.Mail.forget_recipient(address, user.id)
    # The address, off every suppression list (#3036).
    KilnCMS.Mail.forget_suppressions(address, Accounts.list_org_ids())
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

  # The account's row `FOR UPDATE`, first of the erasure's own steps (#2774).
  # Declared before this change, `GuardLastAdmin`'s bootstrap lock and
  # `GuardRegistrationErasure` run ahead of it; every other row the erasure
  # locks comes after. The UPDATE of the row takes the same lock (the email
  # changes), so this only moves it earlier: before `clear_totp/1` and the
  # writes below, which a membership edit waiting on `LockAccount` must not
  # interleave with.
  defp lock_account(changeset) do
    case AccountLock.exclusive(changeset.data.id) do
      {:ok, _state} -> changeset
      {:error, :not_found} -> changeset
    end
  end

  # Strip every site membership of what it grants (#2774). The rows survive
  # erasure — they are the audit of who belonged where, and a rejected
  # registration's row is what keeps the applicant out (#2514) — but a tier,
  # a live temporary one or an audience left on them kept the tombstone an
  # admin on the rosters, an assignee and a reader of gated content.
  defp demote_memberships(user) do
    require Ash.Query

    # authorize?: false — erasure is authorized once, as the `:anonymize` action
    # (or the staging scrub). `:erase` is refused to every actor, and the
    # filter pins every row to this user's id.
    OrgMembership
    |> Ash.Query.filter(user_id == ^user.id and ^granting())
    |> Ash.bulk_update!(:erase, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )
  end

  @doc """
  The memberships that still grant something `OrgMembership.:erase` takes
  away: a tier above `:viewer`, a temporary tier, or an audience. Shared with
  `KilnCMS.Accounts.ErasureBackfill`, so the pass finds exactly what erasure
  now clears.
  """
  @spec granting() :: Ash.Expr.t()
  def granting do
    Ash.Expr.expr(
      role != :viewer or not is_nil(granted_role) or
        fragment("coalesce(cardinality(?), 0) > 0", audiences)
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
    # `:erase`, not `:destroy`: no step-up and no "a passkey was removed"
    # mail, since the address is no longer the owner's.
    KilnCMS.Accounts.Passkey
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.bulk_destroy!(:erase, %{},
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
