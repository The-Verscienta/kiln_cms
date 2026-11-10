defmodule KilnCMS.Security.Changes.RecordRoleChange do
  @moduledoc """
  The audit events (#2241) of a role change, for the actions that write one:
  `User.:manage_access`, and `OrgMembership`'s `:create`, `:update`,
  `:destroy` and `:raise_role_by_invitation` (#2452, always a raise). Built on `KilnCMS.Security.Changes.Record`, in the transaction,
  so the event commits or rolls back with the role.

    * a membership created, or a role raised: `:role_granted` (`role`, and
      `previous_role` when there was one);
    * a role lowered, or a membership removed: `:role_revoked` (`role` is the
      role that was taken away);
    * an edit that leaves the role as it was (audiences, type scopes): nothing.

  The target is the user whose role changed. A user's standing role is global,
  so it is recorded in the org the request ran in (the Ash context's
  `KilnCMS.Security.Recorder.tenant_key/0`); a membership names its own org, so
  the event lands in that org's log whichever org the acting admin is viewing.
  Erasure writes none of these: it forces `role` through `:anonymize`, a
  different action, and clears grants through `:expire_role_grant`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, _opts, context) do
    Record.change(
      changeset,
      [
        type: &type/2,
        tenant: &tenant/2,
        target: fn record, _changeset -> {"user", user_id(record)} end,
        metadata: &metadata/2
      ],
      context
    )
  end

  defp type(record, %{action: %{type: :create}}), do: with_role(record, :role_granted)
  defp type(record, %{action: %{type: :destroy}}), do: with_role(record, :role_revoked)

  defp type(record, changeset) do
    previous = changeset.data.role

    cond do
      previous == record.role -> nil
      RoleGrant.elevation?(record.role, previous) -> :role_granted
      true -> :role_revoked
    end
  end

  defp with_role(%{role: role}, type) when not is_nil(role), do: type
  defp with_role(_record, _type), do: nil

  defp metadata(record, %{action: %{type: :update}} = changeset) do
    if RoleGrant.elevation?(record.role, changeset.data.role),
      do: %{"role" => record.role, "previous_role" => changeset.data.role},
      else: %{"role" => changeset.data.role}
  end

  defp metadata(record, _changeset), do: %{"role" => record.role}

  defp tenant(%OrgMembership{organization_id: org_id}, _changeset), do: org_id
  defp tenant(_user, _changeset), do: nil

  defp user_id(%OrgMembership{user_id: user_id}), do: user_id
  defp user_id(%{id: id}), do: id
end
