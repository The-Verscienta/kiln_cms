defmodule KilnCMS.Accounts.AccountLock do
  @moduledoc """
  A row lock on one `users` row, so erasing a rejected registration (#2514)
  cannot race a write that makes the account more than that registration.

  Erasing an unconfirmed, rejected account (`Changes.EraseRejectedAccount`)
  first checks that the account is nothing but its application: no other
  membership, no paid membership, no API key, nothing authored
  (`KilnCMS.Accounts.Registrations.Erasure`). Under READ COMMITTED that check
  cannot see a membership another transaction is creating at the same moment,
  so the erasure takes the user row `exclusive/1` (`FOR UPDATE`) before it
  checks, and every path that attaches something to an account takes it
  `share/1` (`FOR KEY SHARE`) before it writes:

    * every `OrgMembership` create (`Changes.LockAccount`, resource-wide),
      and the two approvals, before they lock the membership;
    * `Billing.Membership` `:start` and `:comp`, and the entitlement
      recompute's write in `KilnCMS.Billing.Entitlements`, first;
    * `ApiKey` `:create`;
    * the three updates that confirm an unconfirmed account
      (`:confirm_new_user`, `:reset_password_with_token`,
      `:accept_invitation_with_password`).

  The two modes conflict, so whichever transaction locks first goes first and
  the other waits for its commit:

    * the erasure first: the writer waits, then reads the row the erasure
      left and is refused (`{:error, :erased}`), rather than attaching a
      membership, a key or a password to a tombstone;
    * the writer first: the erasure waits, then checks against what the writer
      committed (READ COMMITTED takes a fresh snapshot per statement), and the
      account is kept.

  `FOR KEY SHARE` is the weakest mode that conflicts with `FOR UPDATE`, so
  writers never wait on each other. A foreign-key insert takes it too, which
  covers a create path nobody listed (an `api_keys` row, say), but only in one
  direction: it waits for an erasure, then succeeds against the tombstone.
  That is why the paths above lock explicitly and re-read `anonymized_at`.

  **Lock order** is the users row first, then any membership row, on every
  path, so no two of them can deadlock.

  Both functions must run inside a transaction (they raise otherwise): a row
  lock taken outside one ends with its statement and protects nothing.
  """

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Repo

  @typedoc "The account's state as read under the lock."
  @type state :: %{confirmed?: boolean(), erased?: boolean()}

  @doc """
  Take the user row `FOR KEY SHARE` for the rest of the transaction. `:ok`
  for a live account, `{:error, :erased}` for an erased one, `{:error,
  :not_found}` when there is no such row.
  """
  @spec share(Ash.UUID.t()) :: :ok | {:error, :erased | :not_found}
  def share(user_id) do
    case lock(user_id, :key_share) do
      {:ok, %{erased?: false}} -> :ok
      {:ok, %{erased?: true}} -> {:error, :erased}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Take the user row `FOR UPDATE` for the rest of the transaction, and return
  its state as it stands once the lock is held.
  """
  @spec exclusive(Ash.UUID.t()) :: {:ok, state()} | {:error, :not_found}
  def exclusive(user_id), do: lock(user_id, :update)

  @typedoc "The account's credentials as read under the lock."
  @type credentials :: %{hashed_password: String.t() | nil, totp_pending_secret: binary() | nil}

  @doc """
  Take the user row in `mode` for the rest of the transaction and return the
  credentials a stale request is checked against
  (`KilnCMS.Accounts.Changes.GuardAccountTakeover`, #2453):

    * `:share` (`FOR SHARE`) — for a write that attaches a credential to the
      account (`Passkey.:register`, `PushSubscription.:subscribe`). It waits for
      an invitation's takeover of the account, which holds the row
      `FOR NO KEY UPDATE`, and two such writers never wait on each other;
    * `:no_key_update` (`FOR NO KEY UPDATE`) — for an update of the row itself
      (`User.:confirm_totp`), the lock its own UPDATE takes anyway.

  Neither conflicts with `share/1`'s `FOR KEY SHARE`. Both conflict with
  `exclusive/1`.
  """
  @spec credentials(Ash.UUID.t(), :share | :no_key_update) ::
          {:ok, credentials()} | {:error, :not_found}
  def credentials(user_id, mode) when mode in [:share, :no_key_update],
    do: lock(user_id, mode)

  defp lock(user_id, mode) do
    if not Repo.in_transaction?() do
      raise ArgumentError,
            "KilnCMS.Accounts.AccountLock must run inside a transaction: " <>
              "a lock taken outside one is released before the write it guards"
    end

    case Repo.one(locked(user_id, mode)) do
      nil -> {:error, :not_found}
      state -> {:ok, state}
    end
  end

  defp locked(user_id, :key_share), do: from(_u in row(user_id), lock: "FOR KEY SHARE")
  defp locked(user_id, :update), do: from(_u in row(user_id), lock: "FOR UPDATE")
  defp locked(user_id, :share), do: from(_u in credentials_row(user_id), lock: "FOR SHARE")

  defp locked(user_id, :no_key_update),
    do: from(_u in credentials_row(user_id), lock: "FOR NO KEY UPDATE")

  defp credentials_row(user_id) do
    from(u in "users",
      where: u.id == type(^user_id, Ecto.UUID),
      select: %{hashed_password: u.hashed_password, totp_pending_secret: u.totp_pending_secret}
    )
  end

  defp row(user_id) do
    from(u in "users",
      where: u.id == type(^user_id, Ecto.UUID),
      select: %{confirmed?: not is_nil(u.confirmed_at), erased?: not is_nil(u.anonymized_at)}
    )
  end
end
