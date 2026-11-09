defmodule KilnCMS.Accounts.Changes.DecideRegistration do
  @moduledoc """
  Approves or rejects a registration awaiting a decision (#2251):
  `OrgMembership.:approve_registration` (`outcome: :approve`),
  `:reject_registration` (`outcome: :reject`) and
  `:approve_registration_by_invitation` (`outcome: :approve_by_invitation`,
  #2514).

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
    * approving refuses an **erased** account (`:erased`): erasure keeps the
      row and its confirmation but scrubs the address and the credentials, so
      there is nobody left to let in;
    * approving by invitation is approving, plus: a `:rejected` row is
      approved only when the invitation postdates the rejection (the
      `invited_at` argument later than the row's `decided_at`), and is
      otherwise refused (`:rejected_after_invitation`); a platform admin's
      direct add (`via: :added`) is a decision of its own and skips that
      comparison. The row then takes the
      invitation's `role` and `role_id` arguments;
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
      {:ok, outcome} when outcome in [:approve, :reject, :approve_by_invitation] ->
        {:ok, opts}

      _other ->
        {:error, "outcome: must be :approve, :reject or :approve_by_invitation"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    outcome = Keyword.fetch!(opts, :outcome)
    Ash.Changeset.before_action(changeset, &decide(&1, outcome))
  end

  defp decide(%{data: %{status: status}} = changeset, outcome)
       when status == :pending or (status == :rejected and outcome != :reject) do
    case outcome != :reject && applicant_state(changeset.data.user_id) do
      :unconfirmed ->
        refuse(changeset, :unconfirmed)

      :erased ->
        refuse(changeset, :erased)

      _confirmed_or_rejecting ->
        if superseded_invitation?(changeset, outcome),
          do: refuse(changeset, :rejected_after_invitation),
          else: write(changeset, outcome)
    end
  end

  defp decide(changeset, _outcome),
    do: refuse(changeset, :not_pending)

  # A rejection made after the invitation was sent stands: the invitation is
  # older news than the decision. Equal instants count as older, and so does a
  # rejected row with no decision time (none is written without one): when it
  # cannot be shown that the invitation came later, the rejection stands.
  # A platform admin's direct add (`via: :added`) is a decision made now, by
  # the only actor who may make it: it is not an invitation that could be older
  # news, and comparing two nodes' clocks would only let skew refuse it.
  defp superseded_invitation?(
         %{data: %{status: :rejected} = row} = changeset,
         :approve_by_invitation
       ) do
    Ash.Changeset.get_argument(changeset, :via) != :added and
      older_than_rejection?(changeset, row)
  end

  defp superseded_invitation?(_changeset, _outcome), do: false

  defp older_than_rejection?(changeset, row) do
    invited_at = Ash.Changeset.get_argument(changeset, :invited_at)

    case row.decided_at do
      %DateTime{} = decided_at -> DateTime.compare(invited_at, decided_at) != :gt
      nil -> true
    end
  end

  defp write(changeset, outcome) do
    Ash.Changeset.force_change_attributes(
      changeset,
      Map.merge(
        %{status: status(outcome), decided_at: DateTime.utc_now()},
        invited_tier(changeset, outcome)
      )
    )
  end

  defp invited_tier(changeset, :approve_by_invitation),
    do: %{
      role: Ash.Changeset.get_argument(changeset, :role),
      role_id: Ash.Changeset.get_argument(changeset, :role_id)
    }

  defp invited_tier(_changeset, _outcome), do: %{}

  defp status(:reject), do: :rejected
  defp status(_approve), do: :active

  defp applicant_state(user_id) do
    # authorize?: false — reads the applicant's confirmation as stored; only refuses
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{anonymized_at: %DateTime{}}} -> :erased
      {:ok, %{confirmed_at: %DateTime{}}} -> :confirmed
      _other -> :unconfirmed
    end
  end

  defp refuse(changeset, reason),
    do:
      Ash.Changeset.add_error(
        changeset,
        RegistrationRefused.exception(field: :status, reason: reason)
      )
end
