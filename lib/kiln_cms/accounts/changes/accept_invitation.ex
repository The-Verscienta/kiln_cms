defmodule KilnCMS.Accounts.Changes.AcceptInvitation do
  @moduledoc """
  The invitation half of the two password-setting accept actions on
  `KilnCMS.Accounts.User` (#2135):

    * `:register_with_invitation` — the address has no account yet; this
      creates it;
    * `:accept_invitation_with_password` — the address has an **unconfirmed**
      account, which anyone could have registered for it, so the invitee sets a
      new password over it (the action also revokes every token it held).

  ## What it does, and when

    * **The change body**, when the changeset is built: refuses any call that
      carries an actor (system-only; the admin bypass on `User` would otherwise
      pass the action's `forbid_if always()`), looks the token up, and for a
      new account sets `email` **from the invitation row** — never from input —
      because `email` is required when the changeset is built. A token that
      names nothing live is an error here, so the password is never hashed and
      never sent to the breach lookup for it. For the update, the account must
      be the unconfirmed one the invitation's address holds.
    * **`before_action`**, inside the transaction: the row re-read by token
      under a lock, so two submits of one link serialize and the second finds
      nothing; an `:admin` invitation re-checks that its sender is still a
      standing admin.
    * **`after_action`**, in the same transaction: the membership the
      invitation names (`KilnCMS.Accounts.Invitations.grant_membership/4`), then
      the row consumed. All of it commits with the account or none of it does.
      An unconfirmed account may already be on the site: a lower membership is
      raised to the invited tier, an equal or higher one left alone (#2452).
      What happened rides back on the returned user's metadata, under
      `:invitation_outcome`: `%{outcome: :joined | :raised | :already_member,
      role: tier}`, the tier being the one the account now holds there.

  Every refusal is the one `InvitationRefused` `:invalid` reason, on `:token`.

  The invitation rides in the changeset context under `:invitation` for
  `KilnCMS.Accounts.Changes.CheckBreachedPassword`, which checks the password
  against the invited site's policy for the invited tier.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.AfterCommit
  alias KilnCMS.Security.Recorder

  @effects :accept_invitation_after_commit

  @impl true
  def change(changeset, _opts, %{actor: actor}) when not is_nil(actor), do: invalid(changeset)

  def change(changeset, _opts, _context) do
    token = Ash.Changeset.get_argument(changeset, :token)

    with %Invitation{} = invitation <- Invitations.peek(token),
         true <- Invitations.inviter_still_admin?(invitation),
         true <- account_matches?(changeset, invitation) do
      changeset
      |> put_email(invitation)
      |> Ash.Changeset.set_context(%{invitation: invitation})
      |> Ash.Changeset.before_action(&relock(&1, token))
      |> Ash.Changeset.after_action(&grant/2)
      |> Ash.Changeset.after_transaction(&replay/2)
    else
      _no -> invalid(changeset)
    end
  end

  # A new account takes the invited address. An existing one must already be
  # it, and still unconfirmed — a confirmed account accepts with one click and
  # keeps its password (`Invitation.:accept_existing`).
  defp account_matches?(%{action: %{type: :create}}, _invitation), do: true

  defp account_matches?(%{data: user}, invitation) do
    is_nil(user.confirmed_at) and is_nil(user.anonymized_at) and
      same_address?(user.email, invitation.email)
  end

  defp same_address?(left, right),
    do: String.downcase(to_string(left)) == String.downcase(to_string(right))

  defp put_email(%{action: %{type: :create}} = changeset, invitation),
    do: Ash.Changeset.force_change_attribute(changeset, :email, invitation.email)

  defp put_email(changeset, _invitation), do: changeset

  defp relock(changeset, token) do
    # authorize?: false — the system-only token lookup (the token is the
    # credential), re-read under a row lock inside the accept's transaction.
    case Accounts.get_invitation_by_token(token,
           authorize?: false,
           not_found_error?: false,
           query: Ash.Query.lock(Invitation, :for_update)
         ) do
      {:ok, %Invitation{} = invitation} ->
        if Invitations.inviter_still_admin?(invitation),
          do: Ash.Changeset.set_context(changeset, %{invitation: invitation}),
          else: invalid(changeset)

      _gone ->
        invalid(changeset)
    end
  end

  defp grant(changeset, user) do
    invitation = changeset.context.invitation
    write_context = Map.take(changeset.context, [Recorder.context_key(), Recorder.tenant_key()])

    # A brand-new account (the create) has no legacy tier to carry.
    grant_opts = [carry_legacy?: changeset.action_type != :create]

    # Captured: approving a registration on the way (#2514) leaves an
    # after-commit effect (the applicant's eviction) that must wait for this
    # action's own commit — `replay/2` below.
    {result, effects} =
      AfterCommit.capture(fn ->
        with {:ok, %{outcome: outcome, membership: membership}} <-
               Invitations.grant_membership(user, invitation, write_context, grant_opts),
             # authorize?: false — the system-only consume of the invitation
             # this transaction just honoured.
             :ok <- Accounts.consume_invitation(invitation, authorize?: false) do
          {:ok, %{outcome: outcome, role: membership.role}}
        end
      end)

    with {:ok, outcome} <- result do
      {:ok,
       user
       |> Ash.Resource.put_metadata(@effects, effects)
       |> Ash.Resource.put_metadata(:invitation_outcome, outcome)}
    end
  end

  # Run what `grant/2` captured once the account's transaction has committed
  # (or queue it behind an enclosing `AfterCommit.deferring/1`). A rolled-back
  # accept carries no record, and the effects are dropped with it.
  defp replay(_changeset, {:ok, user}) do
    user.__metadata__ |> Map.get(@effects, []) |> AfterCommit.replay()
    {:ok, %{user | __metadata__: Map.delete(user.__metadata__, @effects)}}
  end

  defp replay(_changeset, other), do: other

  defp invalid(changeset),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvitationRefused.exception(field: :token, reason: :invalid)
      )
end
