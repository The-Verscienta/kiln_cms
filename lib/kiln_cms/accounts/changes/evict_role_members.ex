defmodule KilnCMS.Accounts.Changes.EvictRoleMembers do
  @moduledoc """
  Drops the live sockets of everyone holding a role whose grants changed (#675).

  `KilnCMS.Accounts.Changes.EvictSessions` evicts the user a record names. A
  `Role` names none: `Scoping` resolves membership → role → user, so a role
  carries `editable_types`, `readable_types` and `field_grants` on behalf of
  every member pointing at it. Narrowing one role is therefore a narrowing for
  an unbounded set of people, and evicting "the record's user" reaches nobody.

  So this fans out over the memberships instead. One edit to one role would
  otherwise silently miss every member of it — which is the worst shape this
  class of bug takes, because the admin doing the narrowing has every reason to
  believe it took effect.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.SessionEviction

  @impl true
  def change(changeset, opts, _context) do
    reason = Keyword.get(opts, :reason, changeset.action.name)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      evict_members(record.id, reason)
      {:ok, record}
    end)
  end

  defp evict_members(role_id, reason) do
    OrgMembership
    |> Ash.Query.filter(role_id == ^role_id)
    |> Ash.Query.select([:user_id])
    |> Ash.read!(authorize?: false)
    |> Enum.each(&SessionEviction.evict(&1.user_id, reason))
  rescue
    # Same discipline as `SessionEviction.evict/2`: this runs inside the action
    # that narrowed the grant, and an eviction that could roll it back would
    # leave the role changed and the sockets holding the old one.
    error ->
      require Logger
      Logger.warning("Role member eviction failed for #{role_id}: #{Exception.message(error)}")
      :ok
  end
end
