defmodule KilnCMS.Accounts.Changes.DecideRegistration do
  @moduledoc """
  Approves or rejects a registration awaiting a decision (#2251):
  `OrgMembership.:approve_registration` (`outcome: :approve`) and
  `:reject_registration` (`outcome: :reject`).

  Everything happens in a `before_action` hook, declared **after**
  `get_and_lock_for_update()` on both actions, so it runs on the row as it is
  now, locked for the rest of the transaction — not on the struct the caller
  holds, which a second admin (or a second tab) may already have decided:

    * a row that is not awaiting this decision is refused, so of two decisions
      racing on one row exactly one wins, and a stale page cannot overturn the
      other. Approving accepts a `:pending` or a `:rejected` row (a rejection
      can be reversed); rejecting accepts a `:pending` row only;
    * approving needs a **confirmed** account: anyone can register an address
      they do not own, and approving that would hand the site to whoever did.
      Rejecting needs nothing, so a wave of unconfirmed sign-ups can be cleared;
    * then `status` and `decided_at` are written onto the locked row. Forced,
      not set in the change body: the body runs against the caller's struct,
      and Ash drops a change equal to the data it was built on.

  The applicant's account is read `authorize?: false`: the deciding admin may
  not read other accounts, and the read only decides whether to refuse.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :outcome) do
      {:ok, outcome} when outcome in [:approve, :reject] -> {:ok, opts}
      _other -> {:error, "outcome: must be :approve or :reject"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    outcome = Keyword.fetch!(opts, :outcome)
    Ash.Changeset.before_action(changeset, &decide(&1, outcome))
  end

  defp decide(%{data: %{status: status}} = changeset, outcome)
       when status == :pending or (status == :rejected and outcome == :approve) do
    if outcome == :approve and not confirmed?(changeset.data.user_id) do
      refuse(changeset, :unconfirmed)
    else
      Ash.Changeset.force_change_attributes(changeset, %{
        status: status(outcome),
        decided_at: DateTime.utc_now()
      })
    end
  end

  defp decide(changeset, _outcome),
    do: refuse(changeset, :not_pending)

  defp status(:approve), do: :active
  defp status(:reject), do: :rejected

  defp confirmed?(user_id) do
    # authorize?: false — reads the applicant's confirmation as stored; only refuses
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{confirmed_at: %DateTime{}}} -> true
      _other -> false
    end
  end

  defp refuse(changeset, reason),
    do:
      Ash.Changeset.add_error(
        changeset,
        RegistrationRefused.exception(field: :status, reason: reason)
      )
end
