defmodule KilnCMS.Security.Changes.RecordElevation do
  @moduledoc """
  The audit events (#2241) of a time-boxed elevation (`KilnCMS.Accounts.RoleGrant`),
  for `:grant_temporary_role` on `User` and on `OrgMembership`. In the
  transaction, so the event commits or rolls back with the grant.

    * a grant written: `:elevation_granted` (`role`, and `minutes` until it
      lapses);
    * a grant cleared early: `:role_revoked` (`role` is the elevated role that
      was taken away);
    * a live admin grant replaced by a lower one: both, the lower grant's
      `:elevation_granted` and a `:role_revoked` for the admin grant it ended.

  The sweep that clears a lapsed grant (`:expire_role_grant`) records nothing:
  expiry is a comparison, not an act, and the grant event already carried the
  end time. The target is the user who holds the grant; a membership's event
  lands in its own org's log (see `KilnCMS.Security.Changes.RecordRoleChange`).

  Both events carry `level` (`"site"` for a membership, `"platform"` for the
  account), the early clear `change: "grant_revoked"`, and a grant that
  `KilnCMS.Accounts.LegacyAffiliation` copies onto a legacy account's first
  membership `via: "legacy_carry"` — the security alerts (#2245) read all
  three.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Security.Changes.Record

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Record.change([type: &type/2, metadata: &metadata/2] ++ common(), context)
    |> Record.change(
      [type: &replaced_type/2, metadata: &replaced_metadata/2] ++ common(),
      context
    )
  end

  defp common do
    [
      tenant: fn
        %OrgMembership{organization_id: org_id}, _changeset -> org_id
        _user, _changeset -> nil
      end,
      target: fn record, _changeset -> {"user", user_id(record)} end
    ]
  end

  defp type(record, changeset) do
    cond do
      record.granted_role != nil -> :elevation_granted
      changeset.data.granted_role != nil -> :role_revoked
      true -> nil
    end
  end

  defp metadata(%{granted_role: role} = record, changeset) when not is_nil(role) do
    metadata = %{
      "role" => role,
      "minutes" => minutes(record.granted_role_expires_at),
      "level" => level(record)
    }

    if changeset.context[:kiln_legacy_carry] == true,
      do: Map.put(metadata, "via", "legacy_carry"),
      else: metadata
  end

  defp metadata(record, changeset) do
    %{
      "role" => changeset.data.granted_role,
      "level" => level(record),
      "change" => "grant_revoked"
    }
  end

  # A live admin grant replaced by a lower one takes the admin power away as
  # surely as an early clear does, so it is recorded as one as well: the
  # `:elevation_granted` above names only the new, lower grant.
  defp replaced_type(record, changeset) do
    if admin_grant_replaced?(record, changeset), do: :role_revoked
  end

  defp replaced_metadata(record, _changeset),
    do: %{"role" => "admin", "level" => level(record), "change" => "grant_revoked"}

  defp admin_grant_replaced?(record, changeset) do
    record.granted_role not in [nil, :admin] and changeset.data.granted_role == :admin and
      RoleGrant.live?(changeset.data)
  end

  defp level(%OrgMembership{}), do: "site"
  defp level(_user), do: "platform"

  defp minutes(%DateTime{} = expires_at),
    do: max(DateTime.diff(expires_at, DateTime.utc_now(), :minute), 0)

  defp minutes(_none), do: nil

  defp user_id(%OrgMembership{user_id: user_id}), do: user_id
  defp user_id(%{id: id}), do: id
end
