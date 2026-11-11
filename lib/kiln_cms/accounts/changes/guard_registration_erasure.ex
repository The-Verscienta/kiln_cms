defmodule KilnCMS.Accounts.Changes.GuardRegistrationErasure do
  @moduledoc """
  Holds `User.:anonymize`, run as `SystemActor.new(:registrations)`, to the one
  erasure that actor exists for (#2514): a rejected registration's, from
  `Changes.EraseRejectedAccount`, inside the rejection's own transaction.

  The policy admits that actor to `:anonymize` because the rejection has no
  platform admin to run it as. A policy can only say "this subsystem"; this
  says "this erasure", in a `before_action` hook, in the transaction:

    * the context names the registration (`EraseRejectedAccount.context_key/0`:
      the membership, its site and the `decided_at` the rejection wrote);
    * a transaction is open, and the account's row is taken `FOR UPDATE`
      again (`AccountLock.exclusive/1`; the rejection already holds it, so
      this waits for nothing then);
    * that membership is the account's on that site, is `:rejected` with
      exactly that `decided_at` (the rejection this transaction just wrote,
      not an older one), and recorded that its registration created the
      account;
    * `Registrations.Erasure.check/1` passes.

  Anything else is refused, and the account is not touched. Any other actor
  passes through unchanged: a platform admin's erasure is the policy's alone.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountLock
  alias KilnCMS.Accounts.Changes.EraseRejectedAccount
  alias KilnCMS.Accounts.Errors.ErasureRefused
  alias KilnCMS.Accounts.Registrations.Erasure
  alias KilnCMS.Repo
  alias KilnCMS.SystemActor

  @impl true
  def change(changeset, _opts, %{actor: %SystemActor{subsystem: :registrations}}),
    do: Ash.Changeset.before_action(changeset, &guard/1)

  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "re-checks the registration being erased in the transaction"}

  defp guard(changeset) do
    user_id = changeset.data.id

    with %{membership_id: membership_id, organization_id: org_id, decided_at: %DateTime{} = at} <-
           changeset.context[EraseRejectedAccount.context_key()],
         true <- Repo.in_transaction?(),
         {:ok, _state} <- AccountLock.exclusive(user_id),
         {:ok, %{id: ^membership_id} = membership} <- membership(user_id, org_id),
         true <- rejected_here?(membership, at),
         :erasable <- Erasure.check(membership) do
      changeset
    else
      _refused ->
        Ash.Changeset.add_error(changeset, ErasureRefused.exception([]))
    end
  end

  defp membership(user_id, org_id) do
    # authorize?: false — the registration this erasure names, read to check
    # it; the registrations system actor reads no memberships otherwise
    Accounts.get_org_membership(user_id, org_id, authorize?: false, not_found_error?: false)
  end

  defp rejected_here?(
         %{status: :rejected, created_account: true, decided_at: %DateTime{} = decided},
         at
       ),
       do: DateTime.compare(decided, at) == :eq

  defp rejected_here?(_membership, _at), do: false
end
