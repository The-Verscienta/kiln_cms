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

  Recovery-code regeneration adds no factor and does not carry this change.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.SecondFactorNotice
  alias KilnCMS.AfterCommit

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :kind) do
      {:ok, kind} when kind in [:totp, :passkey] -> {:ok, opts}
      _other -> {:error, "kind: must be :totp or :passkey"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    # Read before the action promotes anything: a confirmed secret on the
    # loaded record means this enrollment replaces it, the same predicate
    # `Validations.RequireCurrentFactorForReplacement` uses.
    factor = factor(Keyword.fetch!(opts, :kind), changeset.data)

    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, record} = result ->
        user_id = owner_id(factor, record)

        AfterCommit.run(fn ->
          SecondFactorNotice.factor_added(user_id, factor, changeset.context)
        end)

        result

      _changeset, result ->
        result
    end)
  end

  defp factor(:totp, %{totp_confirmed_at: %DateTime{}}), do: {:totp, :replaced}
  defp factor(:totp, _first_enrollment), do: {:totp, :added}
  defp factor(:passkey, _data), do: :passkey

  defp owner_id(:passkey, passkey), do: passkey.user_id
  defp owner_id({:totp, _how}, user), do: user.id
end
