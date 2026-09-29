defmodule KilnCMS.Accounts.Changes.RevokeAllTokens do
  @moduledoc """
  Revokes every stored token the user owns, inside the action's own
  transaction, so a password rotation ends every other sign-in (#734).

  ## Why the `log_out_everywhere` flag is not enough

  `KilnCMS.Accounts.User` declares `log_out_everywhere apply_on_password_change?
  true`, and for a long time that line was read as the control. It is not. The
  add-on's transformer registers its change resource-wide as

      change OnPasswordChange,
        on: [:update],
        where: [Changing(:hashed_password, touching?: true)]

  and a `where` is evaluated when the changeset is *built*. Both of our password
  actions (`:change_password`, `:reset_password_with_token`) `accept []` and
  write the hash through `HashPasswordChange`, which does it in a
  `before_action` hook — i.e. after the `where` has already looked and seen
  `hashed_password` untouched. So the condition is false on exactly the actions
  it exists for, nothing is revoked, and the session tokens *and* the thirty-day
  remember-me cookie of whoever held the old password keep authenticating.

  This change is the control; the DSL flag is left declared only so any future
  plain `:update` that does take `hashed_password` as input is covered too.

  ## What it revokes

  Everything `AshAuthentication.AddOn.LogOutEverywhere.Action` does, because it
  *is* that action — reached through `AshAuthentication.Strategy.action/4`, which
  marks the call as AshAuthentication's own, so the `Token` resource's
  AshAuthentication bypass admits it and no `authorize?: false` is needed. That
  is every stored row for the subject that is not already a revocation:

    * `"user"` — every session JWT, on every device;
    * `"remember_me"` — the thirty-day cookie, which otherwise needs no session
      at all to sign someone back in;
    * `"pending_second_factor"` (#742) — a first factor held while a code is
      owed. Deliberately included: a rotation says the old password may be
      known to someone else, and a sign-in parked on it at the code prompt is
      one they may have started. The release is filtered on the hold purpose in
      its own UPDATE, so a revoked hold cannot be resurrected by a late code;
    * pending confirmation / magic-link / reset tokens — all issued to the
      account under the old credential.

  ## Fail direction: closed

  Runs `after_action`, inside the write's transaction. An error from the
  revocation is returned, which rolls the password write back with it: the user
  is told the change failed and can retry, rather than being told it worked
  while the credential it was meant to retire stays live. (The opposite trade
  from `KilnCMS.Accounts.Changes.EvictSessions`, which swallows its failures —
  a broadcast is a prompt, this is the revocation itself.)

  Declare it **before** any change that mints a fresh token for the same user
  (`AshAuthentication.GenerateTokenChange` on `:reset_password_with_token`):
  `after_action` hooks run in declaration order, so the new session is issued
  after the sweep and survives it.

  ## Options

    * `:revoke` — a `(user, context) -> :ok | {:error, term}` function that
      stands in for the revocation. Test-only: it exists so a test can make the
      revocation fail and assert the rollback. It cannot be set from the DSL
      (Spark cannot escape a function), which keeps it off every declared use.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    revoke = Keyword.get(opts, :revoke, &revoke/2)

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case revoke.(user, context) do
        :ok -> {:ok, user}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @doc false
  # The add-on's own action. `Strategy.action/4` sets the
  # `private.ash_authentication?` context both resources' AshAuthentication
  # bypasses key on, and carries the caller's actor/tenant/tracer through.
  @spec revoke(struct(), map()) :: :ok | {:error, term()}
  def revoke(%resource{} = user, context) do
    strategy = AshAuthentication.Info.strategy!(resource, :log_out_everywhere)

    case AshAuthentication.Strategy.action(
           strategy,
           :log_out_everywhere,
           %{user: user},
           Ash.Context.to_opts(context)
         ) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
