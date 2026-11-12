defmodule KilnCMS.Accounts.Changes.ClaimUnconfirmedAccount do
  @moduledoc """
  Hands an unconfirmed account to its address's owner when they sign in to it
  by magic link (#2594), on `User.:take_over_by_magic_link`.

  Anyone can register an unconfirmed account for any address. A magic link
  reaches the address's owner, so following one proves the mailbox and
  nothing else: not that whoever follows it chose the account's password.
  Signing them in and leaving the account as it was would share it with
  whoever registered it first, password and all. So the first magic-link
  sign-in to an unconfirmed account takes it over, as a password reset on one
  does:

    * the account is confirmed (the mailbox is proven);
    * the password is replaced with a random one nobody knows. The owner sets
      their own with a password reset, as after an erasure;
    * the display name the first registrant chose is cleared, as an
      invitation's takeover clears it;
    * the action's other changes revoke every token the account held but the
      magic link itself (`Changes.RevokeAllTokens`), forget its second
      factors, passkeys, identity links, push devices and API keys
      (`Changes.ForgetPriorCredentials`), and evict its live sessions.

  A genuine registrant who signs in by magic link before following their
  confirmation link loses the password they chose. That is the price of the
  link proving only the mailbox: the confirmation link asks for the password
  as well (`User.:confirm_new_user`), and is the way to confirm and keep it.

  ## Decided on the locked row

  The decision is made in a `before_action`, on the row read under
  `FOR NO KEY UPDATE` after `Changes.LockAccount` has refused an erased one:
  an account confirmed since the sign-in read it is refused with
  `Errors.AlreadyConfirmed`, which `Preparations.ClaimUnconfirmedAccount`
  takes as "sign in as usual" and the transaction rolls back untouched.

  ## System-only

  The action is `forbid_if always()`, and the platform-admin bypass would pass
  that, so an actor-carrying call is refused here too. Only the magic-link
  sign-in reaches it (`authorize?: false`): the link is the credential.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AlreadyConfirmed
  alias KilnCMS.Accounts.User

  @impl true
  def change(changeset, _opts, %{actor: actor}) when not is_nil(actor) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidChanges.exception(message: "is system-only")
    )
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &claim/1)
  end

  defp claim(changeset) do
    case locked(changeset.data.id) do
      {:ok, %User{confirmed_at: nil} = row} ->
        %{changeset | data: struct(changeset.data, Map.take(row, [:hashed_password, :name]))}
        |> Ash.Changeset.force_change_attributes(%{
          confirmed_at: DateTime.utc_now(),
          hashed_password: unusable_hash(),
          name: nil
        })

      {:ok, %User{}} ->
        Ash.Changeset.add_error(changeset, AlreadyConfirmed.exception(field: :confirmed_at))

      {:ok, nil} ->
        Ash.Changeset.add_error(changeset, AlreadyConfirmed.exception(field: :id))

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp locked(user_id) do
    # authorize?: false — the system re-read of the account this sign-in is
    # taking over; the magic link is the credential. Only `confirmed_at`,
    # `hashed_password` and `name` are used, and nothing read leaves here.
    Accounts.get_user(user_id,
      authorize?: false,
      not_found_error?: false,
      query: Ash.Query.lock(User, "FOR NO KEY UPDATE")
    )
  end

  # A bcrypt hash of 32 random bytes nobody is told: the account has a valid
  # `hashed_password` (the column is NOT NULL) that no password matches.
  defp unusable_hash do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> Bcrypt.hash_pwd_salt()
  end
end
