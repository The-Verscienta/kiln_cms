defmodule KilnCMS.Accounts.Changes.ForgetPriorCredentials do
  @moduledoc """
  Forgets every credential an unconfirmed account held when an invitation
  takes it over (#2453), on `User.:accept_invitation_with_password`.

  Anyone can register an unconfirmed account for any address. When the
  address's owner then accepts an invitation, they set a new password over
  that account, and `Changes.RevokeAllTokens` ends every session it held. That
  is not enough on its own: whoever registered first may have signed in with
  the password they chose and enrolled a second factor, a passkey or a push
  device, or been minted an API key by an admin. Each of those would go on
  signing them in, or prompting the invitee for a code only the stranger
  holds. This change removes them all, inside the accept's transaction:

    * **two-step verification**: `totp_secret`, `totp_confirmed_at`,
      `totp_pending_secret` and `totp_recovery_hashes` are cleared, so the
      invitee signs in with their password alone and sets their own up;
    * **passkeys**: each destroyed through `Passkey.:forget_on_takeover`;
    * **identity-provider links**: each destroyed through
      `UserIdentity.:forget_on_takeover`;
    * **push devices**: each destroyed through
      `PushSubscription.:forget_on_takeover`;
    * **API keys**: each live one revoked through `ApiKey.:revoke`.

  The account's own tokens are `Changes.RevokeAllTokens`'s, declared above it.

  ## The TOTP columns are read under a row lock, not from the caller's struct

  The update is called with the user struct the caller read, which may be
  older than the row: the stranger could have enrolled a factor since. Ash
  drops a change whose value equals the changeset's `data`, so setting the
  columns to `nil` against a stale struct that already held `nil` writes
  nothing, and the factor enrolled in between survives. So a `before_action`
  re-reads the row `FOR NO KEY UPDATE`, copies its TOTP columns onto the
  changeset's `data`, and only then sets them to empty. The lock waits for any
  concurrent update of the row (an enrolment's `:confirm_totp`) to commit, and
  holds the next one off until this transaction ends. Whether a confirmed
  factor was removed, and so whether `second_factor_removed` is recorded, is
  decided from that fresh row too.

  `FOR NO KEY UPDATE` is the lock the update itself takes. It does not conflict
  with the `FOR KEY SHARE` that `Changes.LockAccount` and every foreign-key
  insert take, so it adds no lock-order hazard against them.

  ## Requests the stranger's session already had in flight

  The sessions are evicted only once this commits, so a request the stranger
  started before it can still land: a passkey registration, a push
  subscription, a two-step confirmation, a recovery-code regeneration, a
  password change. Those writes carry `Changes.GuardAccountTakeover`, which
  takes the same row (`FOR SHARE` for the two creates, `FOR NO KEY UPDATE` for
  the three updates) and refuses the write when the password it was loaded
  with is no longer the account's, or the secret it would promote is no longer
  the one staged. One that reaches the
  row first commits before this reads, and is removed here; one that reaches
  it after waits for this to commit, and is refused.

  ## As the invitations system actor, failing closed

  Every read and write runs as `SystemActor.new(:invitations)`, which each of
  those actions admits and nothing else does; no `authorize?: false`. The reads
  pass `authorize_with: :error`, so a refused read is an error rather than an
  empty list that would leave every credential in place. Any error rolls the
  whole accept back: the invitee is told it failed and can retry, rather than
  being told it worked over an account a stranger can still sign in to.

  The request context and the event tenant (`KilnCMS.Security.Recorder`) ride
  along, so `passkey_removed`, `api_key_revoked` and `second_factor_removed`
  are recorded with no actor in the log of the site the request came from (the
  invited site when the request names none). The API key revocation's socket
  eviction is held until the accept commits, as `Changes.AcceptInvitation`
  holds the membership grant's.

  ## Options

    * `:remove` — a `(changeset, user, opts) -> {:ok, boolean} | {:error,
      term}` function that stands in for the removals. Test-only, as
      `Changes.RevokeAllTokens`' `:revoke` is: it lets a test append a failing
      instance after the declared one and assert the rollback. It cannot be set
      from the DSL (Spark cannot escape a function).

  ## What it reports

  The returned user's `:forgotten_credentials` metadata is `true` when a
  confirmed second factor, a passkey or a live API key was removed: the ones
  the invitee may have to set up again, which `KilnCMSWeb.InviteLive` tells
  them about. Push devices and identity links are removed silently.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.User
  alias KilnCMS.AfterCommit
  alias KilnCMS.Security.Recorder

  @totp_cleared [
    totp_secret: nil,
    totp_confirmed_at: nil,
    totp_pending_secret: nil,
    totp_recovery_hashes: []
  ]

  @effects :forget_prior_credentials_after_commit

  @impl true
  def change(changeset, opts, _context) do
    remove = Keyword.get(opts, :remove, &remove/3)

    changeset
    |> Ash.Changeset.before_action(&clear_totp/1)
    |> Ash.Changeset.after_action(&forget(&1, &2, remove))
    |> Ash.Changeset.after_transaction(&replay/2)
  end

  defp clear_totp(changeset) do
    case fresh(changeset.data.id) do
      {:ok, %User{} = row} ->
        fresh_totp = Map.take(row, Keyword.keys(@totp_cleared))

        %{changeset | data: struct(changeset.data, fresh_totp)}
        |> Ash.Changeset.force_change_attributes(@totp_cleared)
        |> Ash.Changeset.set_context(%{
          forgotten_totp?: not is_nil(row.totp_confirmed_at)
        })

      {:ok, nil} ->
        changeset

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp fresh(user_id) do
    # authorize?: false — the system re-read of the unconfirmed account this
    # accept is taking over, as `Changes.AcceptInvitation` and `InviteLive` read
    # it (the emailed token is the credential); only its TOTP columns are used,
    # and nothing read leaves this change.
    Accounts.get_user(user_id,
      authorize?: false,
      not_found_error?: false,
      query: Ash.Query.lock(User, "FOR NO KEY UPDATE")
    )
  end

  defp forget(changeset, user, remove) do
    {result, effects} =
      AfterCommit.capture(fn -> remove.(changeset, user, write_opts(changeset)) end)

    with {:ok, forgotten?} <- result do
      {:ok,
       user
       |> Ash.Resource.put_metadata(@effects, effects)
       |> Ash.Resource.put_metadata(:forgotten_credentials, forgotten?)}
    end
  end

  @doc false
  # Every removal, as the invitations system actor. `{:ok, forgotten?}`, or
  # the first error.
  @spec remove(Ash.Changeset.t(), User.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def remove(changeset, user, opts) do
    with {:ok, passkeys} <- forget_passkeys(user, opts),
         :ok <- forget_identities(user, opts),
         :ok <- forget_push_subscriptions(user, opts),
         {:ok, keys} <- revoke_api_keys(user, opts),
         :ok <- record_totp_removed(changeset, user, opts) do
      {:ok, changeset.context[:forgotten_totp?] == true or passkeys > 0 or keys > 0}
    end
  end

  defp write_opts(changeset) do
    context =
      changeset.context
      |> Map.take([Recorder.context_key(), Recorder.tenant_key()])
      |> Map.put(Recorder.tenant_key(), tenant(changeset))

    [
      actor: KilnCMS.SystemActor.new(:invitations),
      context: Map.merge(context, AfterCommit.context()),
      rollback_on_error?: false
    ]
  end

  # The request's site, else the invited one: every event needs a log.
  defp tenant(changeset) do
    case changeset.context[Recorder.tenant_key()] do
      org_id when is_binary(org_id) -> org_id
      _none -> changeset.context.invitation.organization_id
    end
  end

  defp reads(opts),
    do: opts |> Keyword.take([:actor, :context]) |> Keyword.put(:authorize_with, :error)

  defp forget_passkeys(user, opts) do
    with {:ok, passkeys} <- Accounts.list_passkeys(user.id, reads(opts)),
         :ok <- each(passkeys, &Accounts.forget_passkey_on_takeover(&1, opts)) do
      {:ok, length(passkeys)}
    end
  end

  defp forget_identities(user, opts) do
    with {:ok, identities} <- Accounts.list_user_identities_for_takeover(user.id, reads(opts)) do
      each(identities, &Accounts.forget_user_identity_on_takeover(&1, opts))
    end
  end

  defp forget_push_subscriptions(user, opts) do
    with {:ok, devices} <- Accounts.list_push_subscriptions(user.id, reads(opts)) do
      each(devices, &Accounts.forget_push_subscription_on_takeover(&1, opts))
    end
  end

  defp revoke_api_keys(user, opts) do
    live = Ash.Query.filter(ApiKey, is_nil(revoked_at))

    with {:ok, keys} <- Accounts.list_api_keys(user.id, Keyword.put(reads(opts), :query, live)),
         :ok <- each(keys, &Accounts.revoke_api_key(&1, opts)) do
      {:ok, length(keys)}
    end
  end

  defp record_totp_removed(changeset, user, opts) do
    if changeset.context[:forgotten_totp?] == true do
      context = Keyword.fetch!(opts, :context)

      case Recorder.record(:second_factor_removed,
             tenant: context[Recorder.tenant_key()],
             user: nil,
             target_type: "user",
             target_id: user.id,
             metadata: %{"kind" => "totp", "via" => "invitation"},
             request: context[Recorder.context_key()]
           ) do
        {:error, error} -> {:error, error}
        _ok_or_skipped -> :ok
      end
    else
      :ok
    end
  end

  defp each(records, fun) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case fun.(record) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # Run what `forget/2` captured once the account's transaction has committed.
  # A rolled-back accept carries no record, and the effects are dropped with it.
  defp replay(_changeset, {:ok, user}) do
    user.__metadata__ |> Map.get(@effects, []) |> AfterCommit.replay()
    {:ok, %{user | __metadata__: Map.delete(user.__metadata__, @effects)}}
  end

  defp replay(_changeset, other), do: other
end
