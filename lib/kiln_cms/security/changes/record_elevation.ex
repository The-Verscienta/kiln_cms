defmodule KilnCMS.Security.Changes.RecordElevation do
  @moduledoc """
  The audit events (#2241) of a time-boxed elevation (`KilnCMS.Accounts.RoleGrant`),
  for `:grant_temporary_role` on `User` and on `OrgMembership`. In the
  transaction, so the event commits or rolls back with the grant.

    * a grant written: `:elevation_granted` (`role`, and `minutes` until it
      lapses);
    * a grant cleared early: `:role_revoked` (`role` is the elevated role that
      was taken away).

  The sweep that clears a lapsed grant (`:expire_role_grant`) records nothing:
  expiry is a comparison, not an act, and the grant event already carried the
  end time. The target is the user who holds the grant; a membership's event
  lands in its own org's log (see `KilnCMS.Security.Changes.RecordRoleChange`).
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, _opts, context) do
    Record.change(
      changeset,
      [
        type: &type/2,
        tenant: fn
          %OrgMembership{organization_id: org_id}, _changeset -> org_id
          _user, _changeset -> nil
        end,
        target: fn record, _changeset -> {"user", user_id(record)} end,
        metadata: &metadata/2
      ],
      context
    )
  end

  defp type(record, changeset) do
    cond do
      record.granted_role != nil -> :elevation_granted
      changeset.data.granted_role != nil -> :role_revoked
      true -> nil
    end
  end

  defp metadata(%{granted_role: role} = record, _changeset) when not is_nil(role) do
    %{"role" => role, "minutes" => minutes(record.granted_role_expires_at)}
  end

  defp metadata(_record, changeset), do: %{"role" => changeset.data.granted_role}

  defp minutes(%DateTime{} = expires_at),
    do: max(DateTime.diff(expires_at, DateTime.utc_now(), :minute), 0)

  defp minutes(_none), do: nil

  defp user_id(%OrgMembership{user_id: user_id}), do: user_id
  defp user_id(%{id: id}), do: id
end
