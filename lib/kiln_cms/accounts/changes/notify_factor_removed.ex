defmodule KilnCMS.Accounts.Changes.NotifyFactorRemoved do
  @moduledoc """
  Mails the account owner that a second factor was removed
  (`KilnCMS.Accounts.SecondFactorNotice.factor_removed/4`), on `User`'s
  `:disable_totp` (`kind: :totp`) and `Passkey`'s `:destroy`
  (`kind: :passkey`): the owner removing their own, and a platform admin
  removing someone else's alike.

  Removing a passkey asks for nothing beyond a signed-in session. Without the
  mail, someone on a stolen or unattended session could narrow the owner's
  ways back in (remove their passkeys, keep their own) and the owner would
  learn of it only from a settings list they have no reason to open.

  After the commit, on success only (`after_transaction` through
  `KilnCMS.AfterCommit.run/1`), as `NotifyFactorAdded` does: a refused
  removal (the last factor a site requires, the shared demo account, a
  policy refusal, a wrong code) mails nobody, and a mail that cannot be
  queued does not undo the removal.

  Whoever ran the action is passed along, so the mail can say when it was an
  administrator rather than the owner.

  Not on `Passkey`'s `:forget_on_takeover` or the factor columns an invitee's
  takeover clears (`Changes.ForgetPriorCredentials`): those are the previous
  holder's, not the owner's. Nor on `Passkey`'s `:erase`
  (`Changes.AnonymizeUser`): the address it would mail is no longer the
  owner's.
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
  def change(changeset, opts, context) do
    kind = Keyword.fetch!(opts, :kind)

    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      notify(changeset, result, kind, context.actor)
    end)
  end

  defp notify(changeset, {:ok, record} = result, kind, actor) do
    user_id = owner_id(kind, record)

    AfterCommit.run(fn ->
      SecondFactorNotice.factor_removed(user_id, kind, actor, changeset.context)
    end)

    result
  end

  defp notify(_changeset, result, _kind, _actor), do: result

  defp owner_id(:passkey, passkey), do: passkey.user_id
  defp owner_id(:totp, user), do: user.id
end
