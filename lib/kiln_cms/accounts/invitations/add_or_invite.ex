defmodule KilnCMS.Accounts.Invitations.AddOrInvite do
  @moduledoc """
  The body of `Invitation.:add_or_invite` (#2135) — what the Team page's
  "Add or invite" does with an address:

  | The address | Result |
  |---|---|
  | belongs to someone already on this site | refused, `:already_member` |
  | has a **confirmed** account with a registration here awaiting approval | the registration approved with the chosen tier, and a notice mail (`:approved`) |
  | has a **confirmed** account with a registration here that was rejected | the same, said as overriding the rejection (`:approved_over_rejection`) |
  | has a **confirmed** account | a membership now, and a notice mail (`:added`) |
  | has a live invitation here | refused, `:already_invited` |
  | has an expired invitation here | sent again with a new token (`:reinvited`) |
  | anything else, an unconfirmed account included | invited (`:invited`) |

  An unconfirmed account is invited, not added: anyone can register an
  unconfirmed account for any address, so adding it would hand a site role to
  whoever did. The invitee proves the address by clicking. That holds for an
  unconfirmed account with a registration here too: accepting the invitation
  approves the registration (`Invitations.grant_membership/4`).

  Approving a registration by adding the address (#2514) is the admin's
  decision, made now, so it overrides a rejection whenever that was made
  (`OrgMembership.:approve_registration_by_invitation`, `via: :added`). The
  outcome names that case, so the Team page can say a rejection was reversed
  rather than let it pass as an ordinary add.

  ## As the actor, all the way down

  Every read and write here runs as the calling admin with authorization on —
  the address lookup, the membership, the invitation — so the policies on
  `User`, `OrgMembership` and `Invitation` decide, not this module. The one
  exception is retiring an invitation a direct add has superseded, a
  system-only write.

  Not one transaction (`transaction? false` is the generic action default): the
  invitation's mail budget is charged in `before_transaction`, which cannot run
  inside one, and the notice mail goes after the membership commits.
  """
  use Ash.Resource.Actions.Implementation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.InvitationRefused
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User.Senders.SendMembershipNotice
  alias KilnCMS.Security.Recorder

  @impl true
  def run(input, _opts, context) do
    args = %{
      organization_id: Ash.ActionInput.get_argument(input, :organization_id),
      email: input |> Ash.ActionInput.get_argument(:email) |> to_string() |> String.trim(),
      role: Ash.ActionInput.get_argument(input, :role) || :viewer,
      role_id: Ash.ActionInput.get_argument(input, :role_id)
    }

    opts = [
      actor: context.actor,
      context: Map.take(input.context, [Recorder.context_key(), Recorder.tenant_key()])
    ]

    with {:ok, user} <- find_user(args.email, opts),
         {:ok, membership} <- membership(user, args.organization_id, opts) do
      cond do
        match?(%{status: :active}, membership) -> refuse(:already_member)
        not confirmed?(user) -> invite(args, opts)
        is_nil(membership) -> add(user, args, opts)
        true -> approve(user, membership, args, opts)
      end
    end
  end

  defp find_user(email, opts) do
    case Accounts.get_user_by_email(email, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, error}
    end
  end

  # The address's row on this site, if any: an active membership, or a
  # registration waiting or rejected (#2251).
  defp membership(nil, _org_id, _opts), do: {:ok, nil}

  defp membership(user, org_id, opts),
    do: Accounts.get_org_membership(user.id, org_id, Keyword.put(opts, :not_found_error?, false))

  defp confirmed?(%{confirmed_at: %DateTime{}}), do: true
  defp confirmed?(_none_or_unconfirmed), do: false

  # --- a confirmed account: a membership now -------------------------------

  defp add(user, args, opts) do
    with {:ok, memberships} <- Accounts.list_memberships_for_user(user.id, opts),
         :ok <- Invitations.carry_legacy_tier(user, memberships, args.organization_id, opts),
         {:ok, membership} <-
           Accounts.create_org_membership(
             %{
               user_id: user.id,
               organization_id: args.organization_id,
               role: args.role,
               role_id: args.role_id
             },
             opts
           ) do
      retire_pending(args, opts)
      notify(user, membership, opts)
      {:ok, %{outcome: :added, membership: membership}}
    end
  end

  # --- a confirmed account with a registration here: approved now ----------

  defp approve(user, registration, args, opts) do
    with {:ok, membership} <-
           Accounts.approve_registration_by_invitation(
             registration,
             %{
               role: args.role,
               role_id: args.role_id,
               invited_at: DateTime.utc_now(),
               via: :added
             },
             opts
           ) do
      retire_pending(args, opts)
      notify(user, membership, opts)
      {:ok, %{outcome: approved_outcome(registration), membership: membership}}
    end
  end

  defp approved_outcome(%{status: :rejected}), do: :approved_over_rejection
  defp approved_outcome(_pending), do: :approved

  # An invitation for an address that has just been added directly is moot;
  # left behind, its link would still work and show a page for a membership
  # that already exists.
  defp retire_pending(args, opts) do
    case pending(args, opts) do
      {:ok, %Invitation{} = invitation} ->
        # authorize?: false — `:consume` is system-only; the admin's membership
        # write for this address just succeeded, and this removes the
        # invitation that write supersedes on the same site.
        Accounts.consume_invitation(invitation, authorize?: false)

      _none ->
        :ok
    end
  end

  defp notify(user, membership, opts) do
    case Accounts.get_organization(membership.organization_id, Keyword.take(opts, [:actor])) do
      {:ok, org} -> SendMembershipNotice.deliver(user, org, membership.role)
      _unreadable -> :ok
    end
  end

  # --- anything else: an invitation ----------------------------------------

  defp invite(args, opts) do
    case pending(args, opts) do
      {:ok, nil} -> create(args, opts)
      {:ok, %Invitation{} = invitation} -> again(invitation, args, opts)
      {:error, error} -> {:error, error}
    end
  end

  defp create(args, opts) do
    case Accounts.invite_to_org(args, opts) do
      {:ok, invitation} ->
        {:ok, %{outcome: :invited, invitation: invitation}}

      {:error, error} ->
        # Two admins inviting one address at once: the identity caught the
        # second, which is the same answer as a pending invitation.
        if pending_conflict?(error), do: refuse(:already_invited), else: {:error, error}
    end
  end

  defp again(invitation, args, opts) do
    if Invitations.live?(invitation) do
      refuse(:already_invited)
    else
      with {:ok, invitation} <-
             Accounts.resend_invitation(
               invitation,
               %{role: args.role, role_id: args.role_id},
               opts
             ) do
        {:ok, %{outcome: :reinvited, invitation: invitation}}
      end
    end
  end

  defp pending(args, opts) do
    case Accounts.list_invitations_for_org(
           args.organization_id,
           Keyword.put(opts, :query, filter: [email: args.email])
         ) do
      {:ok, [invitation | _]} -> {:ok, invitation}
      {:ok, []} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp pending_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &pending_conflict?/1)

  defp pending_conflict?(%{message: message}), do: message == Invitation.pending_message()
  defp pending_conflict?(_other), do: false

  defp refuse(reason),
    do: {:error, InvitationRefused.exception(field: :email, reason: reason)}
end
