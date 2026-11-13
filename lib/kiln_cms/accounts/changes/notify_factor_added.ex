defmodule KilnCMS.Accounts.Changes.NotifyFactorAdded do
  @moduledoc """
  Mails the account owner that a second factor was added (#2247,
  `KilnCMS.Accounts.SecondFactorNotice`), on `User`'s `:confirm_totp`
  (`kind: :totp`, a first enrollment and a replacement alike) and `Passkey`'s
  `:register` (`kind: :passkey`).

  After the commit, on success only (`after_transaction` through
  `KilnCMS.AfterCommit.run/1`), as `MailRegistrationDecision` does: a wrong
  code or a refused registration mails nobody, a mail is never queued for a
  factor that then rolls back, and a mail that cannot be queued does not undo
  the enrollment.

  ## "Set up" or "replaced", from the row

  Whether an authenticator app was already confirmed is read from the
  database in a `before_action`, not from `changeset.data`: the struct a
  settings page passes in is its `current_user` assign, which predates any
  enrollment another tab or device finished since. Declared below
  `GuardAccountTakeover` on `:confirm_totp`, so the read runs after that
  change has taken the row `FOR NO KEY UPDATE`, and a concurrent confirmation
  is serialized ahead of it. Only the mail's wording depends on it; no
  validation reads it.

  Recovery-code regeneration adds no factor and does not carry this change.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SecondFactorNotice
  alias KilnCMS.AfterCommit

  # Where the `before_action` leaves its answer for the `after_transaction`.
  @factor_key :notify_factor_added

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :kind) do
      {:ok, kind} when kind in [:totp, :passkey] -> {:ok, opts}
      _other -> {:error, "kind: must be :totp or :passkey"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> decide(Keyword.fetch!(opts, :kind))
    |> Ash.Changeset.after_transaction(fn
      changeset, {:ok, record} = result ->
        factor = changeset.context[@factor_key]
        user_id = owner_id(factor, record)

        AfterCommit.run(fn ->
          SecondFactorNotice.factor_added(user_id, factor, changeset.context)
        end)

        result

      _changeset, result ->
        result
    end)
  end

  defp decide(changeset, :passkey), do: put_factor(changeset, :passkey)

  defp decide(changeset, :totp) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      put_factor(changeset, {:totp, confirmed_before(changeset)})
    end)
  end

  # A re-read of the very row this action is already authorized to update,
  # for one column that decides the mail's wording and nothing else. Nothing
  # read here leaves the changeset. A missing row falls back to the loaded
  # struct; the update itself then fails.
  defp confirmed_before(changeset) do
    # authorize?: false — re-reads the row this authorized action is updating
    case Accounts.get_user(changeset.data.id, authorize?: false, not_found_error?: false) do
      {:ok, %{totp_confirmed_at: %DateTime{}}} -> :replaced
      {:ok, %{}} -> :added
      _missing -> how(changeset.data)
    end
  end

  defp how(%{totp_confirmed_at: %DateTime{}}), do: :replaced
  defp how(_first_enrollment), do: :added

  defp put_factor(changeset, factor),
    do: Ash.Changeset.put_context(changeset, @factor_key, factor)

  defp owner_id(:passkey, passkey), do: passkey.user_id
  defp owner_id({:totp, _how}, user), do: user.id
end
