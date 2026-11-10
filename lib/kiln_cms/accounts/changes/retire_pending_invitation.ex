defmodule KilnCMS.Accounts.Changes.RetirePendingInvitation do
  @moduledoc """
  When a membership's tier is changed or the membership is removed, the
  invitation still pending for that person on that site goes with it (#2452).

  On `OrgMembership`'s `:update` and `:destroy` only, the writes a site's
  administration makes. Accepting an invitation raises a lower membership
  (`:raise_role_by_invitation`), so an invitation left pending would undo the
  decision just made: demote someone, and the link they still hold would raise
  them back. Retiring it here makes the latest decision the one that stands.
  The invitation paths' own writes (`:raise_role_by_invitation`,
  `:approve_registration_by_invitation`) do not carry this change: they
  consume the invitation they honor themselves.

  It fires when the write changes `role` or `role_id` (a narrower custom role
  is a demotion too), and on every `:destroy`. An edit to the other axes alone
  leaves the invitation alone.

  The invitation is the one for the membership's **own** site and the
  account's address, never the request's host or the acting admin's site.
  It is locked and retired in a `before_action` hook, before the membership
  row is written: the accept path takes the invitation's row first and the
  membership's after it, so this write takes them in the same order, and of an
  accept and an edit on one person cannot take the two rows in opposite
  orders.

  The retirement is `Invitation.:retire`, as `SystemActor.new(:invitations)`,
  which records `invitation_revoked` in the site's log with the person who
  made the membership change as the actor, so an invitation never disappears
  without a trace.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Invitation
  alias KilnCMS.Security.Recorder

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if retires?(changeset), do: retire(changeset, context.actor), else: changeset
    end)
  end

  defp retires?(%{action_type: :destroy}), do: true

  defp retires?(changeset),
    do:
      Ash.Changeset.changing_attribute?(changeset, :role) or
        Ash.Changeset.changing_attribute?(changeset, :role_id)

  defp retire(changeset, actor) do
    %{user_id: user_id, organization_id: org_id} = changeset.data

    with {:ok, %Accounts.User{email: email}} <- account(user_id),
         {:ok, [%Invitation{} = invitation]} <- pending(org_id, email),
         :ok <- retire_invitation(invitation, changeset, actor) do
      changeset
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
      _no_account_or_no_invitation -> changeset
    end
  end

  defp account(user_id) do
    # authorize?: false — a system read of the member's address, to find the
    # invitation that names it; the acting admin may not read other accounts,
    # and nothing read leaves this change.
    Accounts.get_user(user_id, authorize?: false, not_found_error?: false)
  end

  defp pending(org_id, email) do
    query =
      Invitation
      |> Ash.Query.filter(email == ^email)
      |> Ash.Query.lock(:for_update)

    # authorize?: false — a system read of the one invitation on the
    # membership's own site for the member's address, locked so a concurrent
    # accept of it waits; a system actor or an anonymous sweep may be the
    # caller here, neither of which the admin-only read admits.
    Accounts.list_invitations_for_org(org_id, authorize?: false, query: query)
  end

  # As the invitations system actor, the one actor `:retire` admits. The
  # request context and the acting person ride along for the audit event.
  defp retire_invitation(invitation, changeset, actor) do
    context =
      changeset.context
      |> Map.take([Recorder.context_key(), Recorder.tenant_key()])
      |> Map.put(:retired_by, actor)

    Accounts.retire_invitation(invitation,
      actor: KilnCMS.SystemActor.new(:invitations),
      context: context
    )
  end
end
