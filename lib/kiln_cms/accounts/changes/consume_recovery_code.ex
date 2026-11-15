defmodule KilnCMS.Accounts.Changes.ConsumeRecoveryCode do
  @moduledoc """
  Validate-and-burn a 2FA recovery code (#331): the `:code` argument must match
  one of the stored hashes, and the matched hash is removed in the same update —
  so a code can never sign in twice. An unmatched code fails the action.

  ## Burned on the locked row, not the caller's struct

  The update is called with the user struct the request loaded, which may be
  older than the row. Removing the code from *that* list and writing the result
  was a read-modify-write: two requests presenting the same code both found it
  and both succeeded, and two presenting different codes each wrote back the
  list the other had already shortened, restoring a spent code.

  So the burn happens in a `before_action`, on the row re-read
  `FOR NO KEY UPDATE` inside the update's transaction. The lock holds a
  concurrent consume off until this one commits; it then reads the shortened
  list, and a code that is no longer there is refused.

  The code is also checked at build time, against a fresh (unlocked) read, so
  a wrong code is refused before the transaction opens, as it always was.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.User

  @impl true
  def change(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)

    case RecoveryCodes.consume(hashes(read(changeset.data.id, nil), changeset), code) do
      {:ok, _remaining} -> Ash.Changeset.before_action(changeset, &burn(&1, code))
      :error -> invalid(changeset)
    end
  end

  defp burn(changeset, code) do
    fresh = hashes(read(changeset.data.id, "FOR NO KEY UPDATE"), changeset)

    case RecoveryCodes.consume(fresh, code) do
      {:ok, remaining} ->
        # Ash drops a change equal to the changeset's `data`, so the data is
        # set to the row first: the write is then judged against what is stored.
        %{changeset | data: %{changeset.data | totp_recovery_hashes: fresh}}
        |> Ash.Changeset.force_change_attribute(:totp_recovery_hashes, remaining)

      :error ->
        invalid(changeset)
    end
  end

  defp invalid(changeset) do
    Ash.Changeset.add_error(changeset, field: :code, message: "is not a valid recovery code")
  end

  # A miss (the row was deleted) falls back to the struct; the update itself
  # then fails, which is the right outcome.
  defp hashes({:ok, %User{totp_recovery_hashes: hashes}}, _changeset), do: hashes || []
  defp hashes(_miss, changeset), do: changeset.data.totp_recovery_hashes || []

  defp read(user_id, lock) do
    query = if lock, do: Ash.Query.lock(User, lock), else: User

    # authorize?: false — a re-read of the very row this pre-authentication
    # system action is updating, for one private column. Nothing read here
    # leaves the changeset.
    Accounts.get_user(user_id, authorize?: false, not_found_error?: false, query: query)
  end
end
