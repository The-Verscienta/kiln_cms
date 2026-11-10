defmodule KilnCMS.Accounts.Invitations.AcceptExisting do
  @moduledoc """
  The body of `Invitation.:accept_existing` (#2135): the invitation's address
  already has a **confirmed** account, so accepting adds the membership and
  changes nothing on the account. The accept page's one-click branch.

  An unconfirmed account does not come here: its password may not be the
  invitee's, so it goes through `User.:accept_invitation_with_password`, which
  sets a new one and revokes every token the account held. No account at all
  goes through `User.:register_with_invitation`.

  ## System-only

  The action's policy forbids every authorized caller (above the admin bypass),
  and an actor-carrying call is refused here too. `KilnCMSWeb.InviteLive` calls
  it with `authorize?: false`: the token is the credential.

  ## In order, in one transaction

    1. the per-client budget registration uses (`:register`), before the
       transaction, so a flood of clicks is bounded;
    2. the invitation, re-read by token under a row lock — two clicks on one
       link serialize here and the second finds nothing;
    3. an `:admin` invitation still needs its sender to be a standing admin;
    4. the membership (`Invitations.grant_membership/4`): added, or, if the
       account is already on the site below the invited tier, raised to it
       (#2452); at that tier or above, left as it is;
    5. the invitation, consumed — whichever of those it was.

  It returns what happened, `%{outcome: :joined | :raised | :already_member,
  role: tier}`, `role` being the tier the account now holds on the site, so
  the page can say so rather than claim a join that changed nothing.

  Any refusal is the one `:invalid` reason, so a made-up, expired, revoked or
  used link, or a withdrawn admin invitation, all read the same.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ClientIpBudget
  alias KilnCMS.Accounts.Errors.AddressThrottled
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.AfterCommit
  alias KilnCMS.Security.Recorder

  @impl true
  def run(_input, _opts, %{actor: actor}) when not is_nil(actor), do: invalid()

  def run(input, _opts, _context) do
    token = Ash.ActionInput.get_argument(input, :token)
    write_context = Map.take(input.context, [Recorder.context_key(), Recorder.tenant_key()])

    case ClientIpBudget.check(input.context, :register) do
      :allow -> accept(token, write_context)
      {:deny, _retry_after} -> {:error, AddressThrottled.exception(field: :token)}
    end
  end

  # `deferring/1`: approving a registration on the way (#2514) evicts the
  # applicant's sessions through `KilnCMS.AfterCommit`; held here, that leaves
  # after this transaction commits and not at all if it rolls back.
  defp accept(token, write_context) do
    AfterCommit.deferring(fn -> accept_in_transaction(token, write_context) end)
  end

  defp accept_in_transaction(token, write_context) do
    KilnCMS.Repo.transaction(fn ->
      with {:ok, invitation} <- locked(token),
           true <- Invitations.inviter_still_admin?(invitation) || invalid(),
           {:ok, user} <- confirmed_account(invitation),
           {:ok, %{outcome: outcome, membership: membership}} <-
             Invitations.grant_membership(user, invitation, write_context),
           :ok <- consume(invitation) do
        %{outcome: outcome, role: membership.role}
      else
        {:error, error} -> KilnCMS.Repo.rollback(error)
      end
    end)
  end

  defp locked(token) do
    # authorize?: false — the system-only token lookup (the token is the
    # credential); locked so a second click on the same link waits and then
    # finds the row gone.
    case Accounts.get_invitation_by_token(token,
           authorize?: false,
           not_found_error?: false,
           query: Ash.Query.lock(Invitation, :for_update)
         ) do
      {:ok, %Invitation{} = invitation} -> {:ok, invitation}
      _miss -> invalid()
    end
  end

  defp confirmed_account(invitation) do
    # authorize?: false — a system read of the account the invited address
    # holds; the token just proved the address, and nothing read is returned.
    case Accounts.get_user_by_email(invitation.email, authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{confirmed_at: %DateTime{}, anonymized_at: nil} = user} -> {:ok, user}
      _none_or_unconfirmed -> invalid()
    end
  end

  defp consume(invitation) do
    # authorize?: false — the system-only consume of the invitation this
    # transaction just honoured.
    case Accounts.consume_invitation(invitation, authorize?: false) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp invalid, do: {:error, InvitationRefused.exception(field: :token, reason: :invalid)}
end
