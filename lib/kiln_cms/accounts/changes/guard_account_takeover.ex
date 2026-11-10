defmodule KilnCMS.Accounts.Changes.GuardAccountTakeover do
  @moduledoc """
  Refuses a credential write from a request that began before an invitation
  took the account over (#2453).

  Accepting an invitation over an unconfirmed account
  (`User.:accept_invitation_with_password`) sets a new password and forgets
  every credential the account held (`Changes.ForgetPriorCredentials`), then
  evicts the account's sessions once it commits. A request the stranger's
  session already had in flight is past every session check by then: a
  passkey registration, a push subscription, or a two-step verification
  confirmation built before the takeover would land after it, and a passkey is
  a first factor on its own. Worse, `:change_password` checks the current
  password against the struct the request loaded, so the stranger's open
  settings page would accept their own old password and set a new one over the
  invitee's; `:regenerate_totp_recovery_codes` checks its code against the
  stale struct's factor and would write recovery codes the stranger knows.

  Declared on `Passkey.:register` and `PushSubscription.:subscribe` (`:share`)
  and on `User.:confirm_totp`, `:change_password` and
  `:regenerate_totp_recovery_codes` (`:no_key_update`). `:setup_totp` and
  `:disable_totp` are left unguarded on purpose; their declarations say why.

  So these writes take the account's row in a `before_action`, inside their
  own transaction (`KilnCMS.Accounts.AccountLock.credentials/2`), and compare
  it with the struct the request is acting as:

    * `hashed_password` must be the one the actor (or, for an update of the
      user itself, the record) was loaded with. Every takeover changes it, so a
      request that loaded the account before one is refused. (So is one that
      loaded it before an ordinary password change, which revokes every
      session anyway.)
    * with `pending_secret?: true` (`:confirm_totp`), `totp_pending_secret`
      must still be the secret the changeset is about to promote: a takeover
      clears it, and a second `:setup_totp` replaces it.

  The lock is what makes the comparison hold until commit. `:share`
  (`FOR SHARE`) waits for a takeover in flight, which holds the row
  `FOR NO KEY UPDATE`, and then reads what it committed; a takeover that
  starts after it waits for this write to commit, and then lists and removes
  what it wrote. Every path here takes the user row and no other lock first,
  so it adds no lock-order hazard: the takeover takes the invitation row, then
  the user row, then the rest.

  A write whose actor is not the account (a platform admin's, through
  `PushSubscription`'s admin bypass) takes the lock and compares the password
  against nothing it holds; only a struct of the same account is compared.

  Options:

    * `:user_id` — the attribute that names the account (default `:user_id`;
      `:id` on `User` itself);
    * `:lock` — `:share` for a write that attaches a row to the account,
      `:no_key_update` for an update of the account's own row (it waits for
      a takeover in flight just the same);
    * `:pending_secret?` — also compare `totp_pending_secret` (default
      `false`).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.Errors.AccountTakenOver
  alias KilnCMS.Accounts.User

  @impl true
  def init(opts) do
    cond do
      Keyword.get(opts, :lock) not in [:share, :no_key_update] ->
        {:error, "lock: must be :share or :no_key_update"}

      not is_atom(Keyword.get(opts, :user_id, :user_id)) ->
        {:error, "user_id: must be the attribute that names the account"}

      true ->
        {:ok, opts}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    field = Keyword.get(opts, :user_id, :user_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, field) do
        nil -> changeset
        user_id -> guard(changeset, user_id, field, context.actor, opts)
      end
    end)
  end

  defp guard(changeset, user_id, field, actor, opts) do
    case AccountLock.credentials(user_id, Keyword.fetch!(opts, :lock)) do
      {:ok, row} ->
        if same_password?(row, held(changeset, actor, user_id)) and
             same_pending_secret?(row, changeset, opts[:pending_secret?]),
           do: changeset,
           else: Ash.Changeset.add_error(changeset, AccountTakenOver.exception(field: field))

      # A missing account is the foreign key's, or the action's, to refuse.
      {:error, :not_found} ->
        changeset
    end
  end

  # The struct of this account the request holds: the actor, else the record
  # being updated. `nil` when neither is the account.
  defp held(_changeset, %User{id: id} = actor, id), do: actor
  defp held(%{data: %User{id: id} = data}, _actor, id), do: data
  defp held(_changeset, _actor, _user_id), do: nil

  defp same_password?(_row, nil), do: true
  defp same_password?(row, %User{hashed_password: held}), do: row.hashed_password == held

  defp same_pending_secret?(_row, _changeset, flag) when flag != true, do: true

  defp same_pending_secret?(row, changeset, true) do
    staged = changeset.data.totp_pending_secret
    is_binary(staged) and row.totp_pending_secret == staged
  end
end
