defmodule KilnCMS.Accounts.Changes.RevokeAllTokens do
  @moduledoc """
  Revokes every stored token the user owns, inside the action's own
  transaction, so a password rotation ends every other sign-in (#734).

  ## Why not the `log_out_everywhere` flag

  `KilnCMS.Accounts.User` used to declare `log_out_everywhere
  apply_on_password_change? true`, and for a long time that line was read as the
  control. Before AshAuthentication 5.0.0-rc.16 it revoked nothing: the add-on
  gated its resource-wide change on `Changing(:hashed_password, touching?:
  true)`, evaluated when the changeset is *built*, and both of our password
  actions (`:change_password`, `:reset_password_with_token`) `accept []` and
  write the hash through `HashPasswordChange` in a `before_action` hook. So the
  session tokens *and* the thirty-day remember-me cookie of whoever held the old
  password kept authenticating.

  rc.16 fixed the flag (it now checks for a changed hash after the action), and
  Kiln dropped it rather than run two sweeps. The add-on's change is
  resource-wide, so its `after_action` runs after every hook the action
  declares, `GenerateTokenChange` included, and it revoked the session
  `:reset_password_with_token` had just signed its user into. This change sits
  where the action puts it, above the token it must not revoke.

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

  ## The reset token is spared, and revoked by AshAuthentication instead

  On `:reset_password_with_token`, declare this as `{RevokeAllTokens, spare:
  :reset_token}`. Since AshAuthentication 5.0 the strategy's reset revokes the
  reset token itself, in an `after_action` hook added *after* every hook the
  action declares, and that revocation row-locks the token and refuses one
  already marked revoked: it is what makes a reset link single-use. Swept here
  first, the token reached that check already revoked, and every reset failed
  with "token has already been revoked". So the sweep leaves that one jti alone,
  and the strategy revokes it moments later in the same transaction. A reset
  still ends with every token the account held revoked, the reset token
  included, or it rolls back.

  The sparing sweep is the add-on's own bulk revocation with one more filter
  (`AshAuthentication.AddOn.LogOutEverywhere.Action` takes no per-token
  exclusion). It carries the same `private.ash_authentication?` context the
  add-on sets, which is what the `Token` resource's AshAuthentication bypass
  admits, and applies the strategy's `include_purposes`/`exclude_purposes`
  exactly as the add-on does (`exclude_purposes` defaults to `["revocation"]`).

  ## Options

    * `:spare` — the name of a token argument whose jti is left out of the
      sweep: `:reset_token` on the reset (above), `:token` on
      `:take_over_by_magic_link`, whose magic link the sign-in revokes
      single-use after it (#2594).
    * `:revoke` — a `(user, context) -> :ok | {:error, term}` function that
      stands in for the revocation. Test-only: it exists so a test can make the
      revocation fail and assert the rollback. It cannot be set from the DSL
      (Spark cannot escape a function), which keeps it off every declared use.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, context) do
    revoke = Keyword.get(opts, :revoke, default_revoke(changeset, opts[:spare]))

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case revoke.(user, context) do
        :ok -> {:ok, user}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp default_revoke(changeset, argument) when is_atom(argument) and not is_nil(argument) do
    case token_jti(changeset, argument) do
      {:ok, jti} -> &revoke_spared(&1, &2, jti)
      # No readable jti: sweep everything. The strategy's own revocation then
      # finds the token revoked and fails the reset, which is the safe way to
      # be wrong. `ResetTokenValidation` has refused such a token by now anyway.
      :error -> &revoke/2
    end
  end

  defp default_revoke(_changeset, nil), do: &revoke/2

  defp token_jti(changeset, argument) do
    with token when is_binary(token) <- Ash.Changeset.get_argument(changeset, argument),
         {:ok, %{"jti" => jti}} when is_binary(jti) and jti != "" <-
           AshAuthentication.Jwt.peek(token) do
      {:ok, jti}
    else
      _ -> :error
    end
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

  @doc false
  # The add-on's bulk revocation (`LogOutEverywhere.Action`), minus one jti.
  @spec revoke_spared(struct(), map(), String.t()) :: :ok | {:error, term()}
  def revoke_spared(%resource{} = user, context, jti) do
    strategy = AshAuthentication.Info.strategy!(resource, :log_out_everywhere)

    token_resource = AshAuthentication.Info.authentication_tokens_token_resource!(resource)

    action =
      AshAuthentication.TokenResource.Info.token_revocation_revoke_all_stored_for_subject_action_name!(
        token_resource
      )

    token_resource
    |> Ash.Query.filter(jti != ^jti)
    |> include_purposes(strategy.include_purposes)
    |> exclude_purposes(strategy.exclude_purposes)
    |> Ash.bulk_update(
      action,
      %{subject: AshAuthentication.user_to_subject(user)},
      Ash.Context.to_opts(context,
        strategy: [:atomic, :atomic_batches, :stream],
        context: %{private: %{ash_authentication?: true}},
        notify?: true,
        return_errors?: true,
        stop_on_error?: true
      )
    )
    |> case do
      %{status: :success} -> :ok
      %{errors: errors} -> {:error, errors}
    end
  end

  # As `LogOutEverywhere.Action` filters: `nil` means no filter.
  defp include_purposes(query, nil), do: query
  defp include_purposes(query, purposes), do: Ash.Query.filter(query, purpose in ^purposes)

  defp exclude_purposes(query, nil), do: query
  defp exclude_purposes(query, purposes), do: Ash.Query.filter(query, purpose not in ^purposes)
end
