defmodule KilnCMS.Accounts.Changes.MailRegistrationDecision do
  @moduledoc """
  Mails the applicant a registration decision (#2251), on
  `OrgMembership.:approve_registration` (`outcome: :approve`) and
  `:reject_registration` (`outcome: :reject`).

  After the commit, on success only (`after_transaction` through
  `KilnCMS.AfterCommit.run/1`): a refused decision mails nobody, and a mail
  that cannot be queued does not undo the decision.

  Nobody is mailed when the address is not a proven one: a rejection of an
  unconfirmed registration (rejecting is allowed before confirmation, so a
  wave of sign-ups with other people's addresses can be cleared, and mailing
  those would aim the site's mail at strangers), and any decision about an
  erased account. Reversing a rejection mails the approval like any other.

  The applicant's account is read `authorize?: false`, on the same terms as
  `DecideRegistration`: the deciding admin may not read other accounts, and
  the read only decides whether, and where, to send. The site is read as
  `KilnCMS.Accounts.system/0`.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User.Senders.SendRegistrationDecision
  alias KilnCMS.AfterCommit

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

    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, membership} = result ->
        AfterCommit.run(fn -> mail(outcome, membership) end)
        result

      _changeset, result ->
        result
    end)
  end

  defp mail(outcome, membership) do
    with {:ok, applicant} <- applicant(membership.user_id),
         {:ok, org} <-
           Accounts.get_organization(membership.organization_id,
             actor: Accounts.system(),
             authorize_with: :error
           ) do
      SendRegistrationDecision.deliver(outcome, applicant, org, membership.role)
    else
      :skip ->
        :ok

      {:error, error} ->
        Logger.error(
          "registration decision for membership #{membership.id} not mailed: " <>
            Exception.message(error)
        )
    end
  end

  defp applicant(user_id) do
    # authorize?: false — reads the applicant's address and confirmation as
    # stored, to decide whether and where to mail; the deciding admin may not
    # read other accounts (same justification as `DecideRegistration`)
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{confirmed_at: %DateTime{}, anonymized_at: nil} = user} -> {:ok, user}
      {:ok, _unproven_or_erased} -> :skip
      {:error, error} -> {:error, error}
    end
  end
end
